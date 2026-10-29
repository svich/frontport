# Scripts

## release.sh

Builds a Frontport release: Developer ID–signed, notarized and stapled, zipped, with a signed entry in the Sparkle appcast.

```sh
scripts/release.sh --dry-run   # every step up to the first one that needs a credential
scripts/release.sh
```

In order, it:
1. **Prepares:** checks the tools, generates `Frontport.xcodeproj`, resolves the Swift packages into `build/release/DerivedData`, finds Sparkle's `generate_appcast`, and reads the version from the Release build settings.
2. **Checks every credential before building:** the Developer ID identity in the login keychain, the notarytool profile, the Sparkle key in the Keychain, and `SUPublicEDKey` (the key's public half) and `SUFeedURL` in `App/Resources/Info.plist`. Anything missing stops the script with what to do.
3. **Builds:** archives the Release configuration and exports it for Developer ID, which re-signs everything inside, Sparkle's helpers included, with the hardened runtime and a secure timestamp.
4. **Verifies the signature:** `codesign --verify --strict --deep`, the Developer ID authority, the timestamp, no `get-task-allow`, and the hardened runtime on every executable, `frontport-primer` included.
5. **Notarizes:** `xcrun notarytool submit --keychain-profile <profile> --wait`, then staples the ticket and checks that `spctl -a -vv` accepts the app as Notarized Developer ID. A rejection saves notarytool's log in `build/release/`.
6. **Publishes to the appcast:** zips the stapled app into `build/release/updates/` and runs Sparkle's `generate_appcast`, which signs the entry with the EdDSA key from the Keychain.

`--dry-run` does step 1 and reports any Info.plist problem, then stops before step 2. It exits with 1 when a release would stop at Info.plist.

| Option | Environment | Default | What it is |
|---|---|---|---|
| `--profile` | `FRONTPORT_NOTARY_PROFILE` | `frontport` | The notarytool Keychain profile |
| `--key-account` | `FRONTPORT_SPARKLE_ACCOUNT` | `ed25519` | The Keychain account of Sparkle's EdDSA key |
| `--output` | `FRONTPORT_RELEASE_DIR` | `build/release` | Where the archive, the export and `updates/` go |
| `--download-url-prefix` | `FRONTPORT_DOWNLOAD_URL_PREFIX` | `SUFeedURL`'s folder | Where users download the zips from |
| | `FRONTPORT_SIGNING_IDENTITY`, `FRONTPORT_TEAM_ID` | `App/Signing.local.xcconfig` | The identity and team, for one run |

## One-time setup

1. **Developer ID certificate.** Create a Developer ID Application certificate (the team's Account Holder can, in Xcode: Settings → Accounts → Manage Certificates), so it's in the login keychain. Then put the identity and team in `App/Signing.local.xcconfig`, which git ignores and `App/Signing.xcconfig` includes:

   ```text
   CODE_SIGN_IDENTITY = Developer ID Application
   DEVELOPMENT_TEAM = <team ID>
   ```

   Any identity other than ad-hoc turns the hardened runtime on for the app and `frontport-primer`.

2. **notarytool profile.** Store the credentials notarytool uses in the Keychain, under the profile name the script expects. With an app-specific password from [account.apple.com](https://account.apple.com):

   ```sh
   xcrun notarytool store-credentials frontport --apple-id <Apple Account> --team-id <team ID> --password <app-specific password>
   ```

   or with an App Store Connect API key: `--key <AuthKey_….p8> --key-id <key ID> --issuer <issuer ID>` instead of the last three.

3. **Sparkle key.** Run a dry run once so the Sparkle package is resolved, then generate the EdDSA key pair:

   ```sh
   build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   It keeps the private key in the login Keychain (account `ed25519`) and prints the public key. Export a backup with `generate_keys -x <file>` and keep it in a password manager: without the key, installed copies can't verify updates.

4. **Info.plist.** In `App/Resources/Info.plist`, add the public key and replace the placeholder feed URL with where `appcast.xml` will be served:

   ```xml
   <key>SUPublicEDKey</key>
   <string><the public key generate_keys printed></string>
   <key>SUFeedURL</key>
   <string>https://<host>/appcast.xml</string>
   ```

   Sparkle starts only when `SUPublicEDKey` is present, so builds without it never check for updates.

## Each release

1. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Sparkle orders updates by `CURRENT_PROJECT_VERSION` (`CFBundleVersion`), so it must grow every release.
2. Keep `build/release/updates/` from the last release, or put the published `appcast.xml` and recent zips back into it: `generate_appcast` adds to the appcast it finds there and makes delta updates from the older zips.
3. Run `scripts/release.sh`.
4. Upload `updates/Frontport-<version>.zip` and any new deltas to the download location, then `updates/appcast.xml` to `SUFeedURL`.
