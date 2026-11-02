# Install Ports on iPhone and iPad, signed with the user's own Apple Team

**Status:** proposed (2026-10-31). Implemented up to installing prebuilt iOS versions, Seeding, Renew and Update, and tested over stand-ins for `devicectl`, Xcode and the keychain; on a real Device only the spikes and the opt-in tests have run (DESIGN › Devices).

Some Projects also make iOS versions of their Ports: Fallout CE and Fallout 2 CE publish an `.ipa`, Xash3D FWGS one in its `continuous` release, and Ghostship an iOS zip. An iPhone or iPad runs only code signed by Apple or by a developer whose provisioning profile names that Device. ADR 0001's ad-hoc signature doesn't run there. So Frontport, on the Mac, makes the iOS version and installs it on the user's own Devices:

- **The Catalog says which Ports have an iOS version,** in an entry's `ios`: its own Releases, prebuilt or from a Recipe, where each Requirement is Seeded in the app's container, and where Build Assets go inside the app. A Port without `ios` stays on the Mac. The Catalog lists it only once upstream supports iOS for players, so Arcanum CE, which builds for iOS but says it isn't ready to play, isn't listed.
- **Frontport builds on the Mac, as it does for the Mac.** A prebuilt `.ipa` is fetched and checked against its digest. A Recipe runs in the build sandbox against the iOS SDK and leaves one unsigned `.app` built for `iphoneos`.
- **It signs with the user's Apple Team,** the Apple developer team of the Apple Development certificate in the user's keychain, and a development Provisioning Profile for the Port's bundle ID that names the Device. The bundle ID is `dev.frontport.port.<id>.<team>`, the Apple Team's ID in lowercase, because an explicit App ID belongs to the one Apple Team that registered it.
- **Xcode makes the Provisioning Profiles.** Frontport first takes one Xcode already has in `~/Library/Developer/Xcode/UserData/Provisioning Profiles`: unexpired, for the Apple Team, for that bundle ID or a wildcard covering it, naming the Device, with its certificate's key in the keychain. Without one, it writes a stub app project with that bundle ID and runs `xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration` for the Device, so Xcode, signed in with the account the user added in its Settings › Accounts, registers the App ID and the Device and downloads the Provisioning Profile. Frontport never signs in to Apple.
- **It installs and Seeds with `devicectl`.** `xcrun devicectl device install app` installs over USB or Wi-Fi, keeping the app's Data on an update. `devicectl device copy to --domain-type appDataContainer` copies the Runtime ROMs into the app's container, such as Fallout's game files into `Documents/`, where upstream tells players to put them with Finder's file sharing.
- **iOS is the sandbox.** Every iOS app runs in its own container, development-signed ones included. Frontport gives a Port only the entitlements a Provisioning Profile always carries (`application-identifier`, the Apple Team's, `get-task-allow`) and never a capability such as iCloud.

## Considered Options

- **Signing with the user's Apple ID and password,** as AltStore, SideStore and Sideloadly do. Frontport would hold an Apple sign-in, which it never does, for Steam or for Apple.
- **Asking the user to sign each Port in Xcode.** It works, but means a project per Port and every renewal by hand.
- **TestFlight or the App Store.** Frontport doesn't distribute Ports, and a Port with Build Assets carries files made from the user's ROM.
- **Exploit-based installers such as TrollStore.** They work only on old iOS versions and lift the sandbox.
- **Only the iOS Simulator.** It needs no signing, but it isn't the user's iPhone. It may still come later, for testing Recipes.

## Consequences

- **Full Xcode is needed,** not just the Command Line Tools, with the iOS platform and the user's Apple account added. Frontport asks for it the first time the user installs on a Device, so Mac-only users never need it.
- **A free Apple Team has Apple's limits.** Its Provisioning Profiles last 7 days, so the Port stops launching until Frontport Renews it; at most 3 of the user's own apps run on a Device at once; and at most 10 App IDs can be registered a week. A paid one's last a year, and its wildcard Provisioning Profile needs no new App ID. Frontport reports `devicectl`'s or Xcode's error as it comes rather than counting for Apple.
- **Renewing needs the Device.** It re-signs the kept app with a new Provisioning Profile and installs it over, which keeps Data, but only while Frontport is open and the Device is unlocked and reachable.
- **Data lives on the Device.** Deleting the app there, or Uninstall, deletes its Data with it; iOS keeps nothing. Snapshots of a Device's Data, through `devicectl device copy from`, are deferred.
- **Permissions don't all hold.** iOS gives every app the network, so a Port's Network Permission can't be withheld there. Files the user picks go through iOS's own picker, and controllers need nothing.
- **The bundle ID differs from the Mac's.** A Port's Mac and iOS versions keep separate Data, as they would anyway on separate machines.
- **The first signature asks for the keychain.** macOS asks once whether `codesign` may use the Apple Team's private key; Always Allow covers later ones.
