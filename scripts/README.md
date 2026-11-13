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

1. **Developer ID certificate.** Only the team's Account Holder can create a Developer ID Application certificate. Xcode's Settings → Accounts → Manage Certificates → + may refuse with "only be performed by the Account Holder" even for the holder of an Individual membership; the website works:

   ```sh
   openssl genrsa -out key.pem 2048
   openssl rsa -in key.pem -out key1.pem -traditional   # security import takes PKCS#1, not OpenSSL 3's PKCS#8
   security import key1.pem -k ~/Library/Keychains/login.keychain-db -t priv -f openssl -T /usr/bin/codesign -T /usr/bin/security
   openssl req -new -key key.pem -out DeveloperID.certSigningRequest -subj "/CN=<name> Developer ID/C=<country>"
   rm -P key.pem key1.pem
   ```

   Upload the request at [developer.apple.com/account/resources/certificates/add](https://developer.apple.com/account/resources/certificates/add) as Developer ID Application (G2 Sub-CA), download the `.cer` and `security import` it into the login keychain, where it pairs with the key. Export the pair as a `.p12` from Keychain Access as a backup. `security find-identity -v -p codesigning` then lists `Developer ID Application: <name> (<team ID>)`.

   Pass the identity to the script per run (see [Each release](#each-release)), so `App/Signing.local.xcconfig` keeps Apple Development for everyday builds. Putting it there instead also works:

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
   <string>https://github.com/svich/frontport/releases/latest/download/appcast.xml</string>
   ```

   Frontport's feed is the appcast attached to the latest GitHub Release; GitHub redirects that URL to it.

   Sparkle starts only when `SUPublicEDKey` is present, so builds without it never check for updates.

## Each release

Each release is a GitHub Release, `v<version>`, carrying its zip and the whole appcast. `SUFeedURL` is the latest release's `appcast.xml`, so publishing a release is publishing the update; older entries keep pointing at their own release's zip.

1. **Version.** Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Sparkle orders updates by `CURRENT_PROJECT_VERSION` (`CFBundleVersion`), so it must grow every release. Commit, and push `main`, so the tag names the commit that was built.
2. **Appcast.** Start from the published appcast alone, without any zips:

   ```sh
   rm -rf build/release/updates
   gh release download --repo svich/frontport --pattern appcast.xml --dir build/release/updates
   ```

   `generate_appcast` rewrites the URL of every entry whose zip it finds in the folder to this release's `--download-url-prefix`, which would point older entries at files this release doesn't carry. Without the older zips it adds the new entry and leaves the others alone, at the cost of delta updates.
3. **Build.** Run the script with the Developer ID and this release's download folder (about 5 minutes, most of it notarization):

   ```sh
   FRONTPORT_SIGNING_IDENTITY="Developer ID Application" FRONTPORT_TEAM_ID=<team ID> \
       scripts/release.sh --download-url-prefix https://github.com/svich/frontport/releases/download/v<version>/
   ```

   It stops before building if a credential is missing, and saves notarytool's log in `build/release/` on a rejection.
4. **Publish:**

   ```sh
   gh release create v<version> --repo svich/frontport --target <commit> --title "Frontport <version>" --notes "<what changed>" \
       build/release/updates/Frontport-<version>.zip build/release/updates/appcast.xml
   ```

5. **Check** that the feed serves the new appcast and that the published zip passes Gatekeeper:

   ```sh
   curl -sL https://github.com/svich/frontport/releases/latest/download/appcast.xml | cmp - build/release/updates/appcast.xml
   ditto -x -k <downloaded zip> <empty folder> && spctl -a -vv <empty folder>/Frontport.app   # source=Notarized Developer ID
   ```

## What expires

- **Apple Developer Program membership:** renews every year. Without it notarization stops, so no new releases; releases already out keep working.
- **Developer ID Application certificate:** until the date the portal shows (the current one, Dec 13, 2027; `security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -enddate`). Releases signed before it expires keep working, thanks to the secure timestamp. Make a new one as in step 1 of the setup.
- **notarytool profile:** stops working if its app-specific password is revoked. Store it again with `store-credentials`.
- **Sparkle key:** never expires, but can't be replaced: installed copies accept only updates signed with it. Restore a lost Keychain copy from the backup with `generate_keys -f <file>`.
