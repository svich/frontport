# Contributing to Frontport

Thanks for your interest in Frontport. Bug reports, feature ideas,
documentation fixes and code are all welcome.

## Issues

Search [existing issues](https://github.com/svich/frontport/issues) first to
avoid duplicates, then open a new one.

For bugs, include:

- your macOS version and Mac model (Apple silicon or Intel);
- the Frontport version or commit you are running;
- what you did, what you expected, and what happened instead; and
- logs or screenshots, if you have them.

For feature requests, describe the problem you want solved, not only the
solution you have in mind.

## Pull requests

1. For anything beyond a small fix, open an issue first so we can agree on the
   approach before you spend time on it.
2. Fork the repository and create a branch from `main`.
3. Keep each pull request focused on one change. Don't mix in unrelated
   refactoring or formatting.
4. Describe what you changed and why, how you tested it, and link the related
   issue.
5. Accept the CLA, as described below. Pull requests can't be merged until
   every author has accepted it.

## Contributor License Agreement

Before your contributions can be merged, you must accept the
[Contributor License Agreement](CLA.md). You keep the copyright in your work;
the CLA gives the project owner a license to use it, including in official
proprietary or commercially licensed editions of Frontport. The
[summary at the top of the CLA](CLA.md#summary) explains what you agree to and
why.

When you open a pull request, a bot asks you to accept the CLA if you haven't
already. To accept, post a comment on the pull request containing exactly:

```text
I have read the Frontport Individual Contributor License Agreement version 1.0 and I accept it
```

See [Accepting this Agreement](CLA.md#accepting-this-agreement) for details.
Ticking a checkbox or adding a `Signed-off-by` line does not count as
acceptance. You only need to accept once per CLA version, and each co-author
must accept separately.

If you write code as part of your job, your employer may own it. See
[Contributing for an employer or organization](CLA.md#contributing-for-an-employer-or-organization)
before submitting.

## Project structure

- `App/`: the Frontport app target (SwiftUI views, `AppModel`, resources).
- `App/Testport/`: Testport, a stand-in Port the UI tests install. It isn't
  part of Frontport.
- `FrontportKit/`: a Swift package with all non-UI logic, one module per
  component in [docs/DESIGN.md](docs/DESIGN.md#components). Every module
  depends only on `FrontportCore`, which holds the shared types and service
  protocols.
- `catalog/`: the Catalog source and its Recipes.
- `project.yml`: the XcodeGen spec. `Frontport.xcodeproj` is generated and not
  committed.

When adding files:

- put new files next to the code they relate to;
- don't move or rename existing files in a pull request that does something
  else; and
- discuss larger reorganizations in an issue first.

## Swift conventions

- Follow the
  [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
  and the style of the surrounding code.
- Keep SwiftUI views small and composable. Move logic that doesn't need to
  live in a view into separate types that can be tested.
- Make state ownership clear: keep `@State` private to the view that owns it,
  and pass data down rather than reaching for global state.
- Prefer value types and `let` where possible.
- Avoid force unwrapping (`!`) and `try!` outside tests unless failure is
  truly impossible, and say why in a comment.
- If a formatter or linter configuration is added to the repository, run it
  before submitting.

## Build and test expectations

You need Xcode 27 and [mise](https://mise.jdx.dev). `mise install` installs
the pinned [XcodeGen](https://github.com/yonaskolb/XcodeGen). The tasks are:

- `mise run generate`: generate `Frontport.xcodeproj`;
- `mise run build`: build the app into `build/`;
- `mise run test`: run the FrontportKit tests;
- `mise run uitest`: drive the app's UI end to end (see below); and
- `mise run run`: build and open the app.

Builds are signed ad-hoc ("Sign to Run Locally") without the hardened
runtime, in Debug and Release alike: under it, library validation would
reject the ad-hoc Sparkle framework and the app would crash at launch. To sign
with a Developer ID, create `App/Signing.local.xcconfig`, which git ignores:

```text
CODE_SIGN_IDENTITY = Developer ID Application
DEVELOPMENT_TEAM = <your team ID>
```

The hardened runtime then turns on for the app and `frontport-primer`
together. Release builds never carry the `get-task-allow` entitlement. See
`App/Signing.xcconfig`.

Tests that reach GitHub, download real Ports or launch them are opt-in:
`FRONTPORT_NETWORK_TESTS=1 swift test --filter FrontportIntegrationTests`
in `FrontportKit` installs, launches, updates and removes real Ports. They
run in the Ports' real containers in `~/Library/Containers`, and delete
their Data afterwards. `mise run test-synthetic` runs the same modules
offline against a local server, with synthetic ROMs and stand-in Ports, to
check Seeding, Build Assets and Catalog refresh without real games.

`mise run release` builds, signs, notarizes and staples a release and
updates the Sparkle appcast; see [scripts/README.md](scripts/README.md) for
the one-time setup. `scripts/release.sh --dry-run` checks everything up to
the first step that needs a credential.

A Debug build keeps its files in the folder `FRONTPORT_ROOT` names instead
of `~/Library/Application Support/Frontport`, so you can try it on a
scratch Library. `-FrontportSnapshots <dir>` renders every screen to PNGs
from sample data; add `-FrontportSnapshotsLive` to render the real state.
Leave the window alone while it runs: once it's the active window, the
detail column captures blank (the traffic lights show in color), so run it
again. The shots are drawn with `cacheDisplay`, which skips Liquid Glass:
the glass is a backdrop layer and a glass button's label is tinted by a
filter. `SnapshotDriver` redraws the sidebar, the toolbar buttons and glass
buttons (`SDFLayer`s) on flat stand-ins. A prominent button's tint isn't in
any layer it can read, so the button shows as plain glass. A glass control
it doesn't know captures as a bare label, or as nothing. Check new glass in
both appearances before trusting the shot.

Each screen's file ends with Xcode previews over the same sample data, one
per state worth seeing: open the file and the canvas shows the screen in the
main window. `ScreenPreview` (`App/Sources/Views/Debug/Previews.swift`) picks
the screen and can change the model, the `ViewState` or a Catalog entry
first, to add a state.

`mise run uitest` runs the XCUITest suite in `App/UITests`. Each test
launches the Debug app on its real services over a fresh `FRONTPORT_ROOT`.
To run them:

- unlock the Mac, and approve the prompt (Touch ID or password) that macOS
  shows to turn on Automation Mode for UI testing; and
- keep the screen unlocked until the run ends, since the tests drive the
  real window.

The lifecycle test installs, plays and removes Testport (`App/Testport`), a
small stand-in Port that reports the ROM it finds in its Data. The test
publishes it from a local server, as an upstream Port is published: a test
Catalog signed with a key the test makes, a GitHub-style release list and
the zipped app. It adds a synthetic ROM, so it needs neither the network
nor a real game. It runs Testport in its real container,
`dev.frontport.port.testport`, skips itself while that container has Data,
and deletes the Data it made. The Catalog and Releases tests read the
bundled Catalog and reach GitHub's API without a token, which allows 60
requests an hour. They keep GitHub's answers in
`$TMPDIR/FrontportUITests/releases-cache` between launches, so only a run
without that cache spends much of the limit.

One test runs a real Port, so it runs only when you ask for it. It doesn't
run while the Port's container has Data, and it deletes the Data it made.

- `TEST_RUNNER_FRONTPORT_REAL_PORTS=1 mise run uitest` takes Zelda 64:
  Recompiled through the same life as Testport, with a stand-in ROM. It
  downloads about 30 MB from GitHub. Zelda crashes as it quits, so macOS
  shows a "quit unexpectedly" dialog, and the test expects that crash.
  Don't run it at the same time as the FrontportKit integration tests,
  which use the same container.

Debug-only launch arguments stand in for what a test can't provide:

- `-FrontportImportROMs <file>` makes Add ROMs… add that file instead of
  showing the open panel;
- `-FrontportAcceptROM <port>=<sha1>` makes the Catalog accept that hash for
  the Port's Runtime ROM;
- `-FrontportCatalogURL <url> -FrontportCatalogKey <base64>` loads the
  Catalog from that folder, verified with that Ed25519 public key instead of
  the built-in one, and ignores the bundled Catalog; and
- `-FrontportGitHubAPI <url>` discovers Releases from that stand-in for
  GitHub's API.

Before submitting a pull request:

- make sure the project builds without errors or new warnings;
- run the existing tests and make sure they pass;
- add or update tests for logic you change, where practical; and
- run the app and check your change by hand, and say in the pull request
  what you tested.

## Third-party code and dependencies

Frontport is distributed under GPL-3.0 and may also be distributed by the
project owner under other licenses, so all code must be either your own or
clearly identified.

- **Raise new dependencies in an issue or pull request first.** Name the
  package, version, source URL and license.
- **Prefer permissive licenses**, such as MIT, BSD, zlib or Apache-2.0. They
  are compatible with GPL-3.0 and don't prevent the project owner from
  offering other editions. See the GNU
  [license list](https://www.gnu.org/licenses/license-list.html) for
  compatibility details.
- **Code under the GPL, LGPL, AGPL or other copyleft licenses, or under
  "non-commercial" or unclear licenses**, needs approval from the project
  owner before it is added, because it may not be possible to relicense.
- **Don't copy code from other projects** into a contribution without saying
  so in the pull request, as described in section 8 of the [CLA](CLA.md).

## Copyright and attribution

- You keep the copyright in your contributions; see section 2 of the
  [CLA](CLA.md). Git history records who wrote what.
- Don't remove or change existing copyright, license or attribution notices.
- Keep the original copyright and license notices of any third-party code
  you include, and mention them in your pull request.
- List third-party images and other bundled content in
  [CREDITS.md](CREDITS.md), with the source and license.
- Don't add per-file license headers unless the project adopts a header
  template; if it does, follow it.
- Code written with AI tools is held to the same standard: you must review
  it, understand it, and have the right to submit it.

## Content you must not submit

Never submit:

- copyrighted game assets, including ROMs, disc images, executables,
  textures, models, audio, video or text from games;
- proprietary console keys, encryption or signing keys, firmware or BIOS
  files;
- leaked or proprietary SDKs, source code or documentation;
- any other code or content you don't have permission to distribute under
  the [CLA](CLA.md) and GPL-3.0; or
- secrets, such as API keys, passwords, certificates or code-signing
  identities.

Contributions containing any of these will be rejected, and may be removed
from the repository's history.

## Trademarks

Contributing doesn't grant any rights to the Frontport name, logo or icons.
If you publish a fork, see the [Trademark Policy](TRADEMARKS.md) for how to
brand it.

## License

Frontport is licensed under the [GNU General Public License v3.0](LICENSE).
Your contributions will be published under GPL-3.0 and, under the terms of the
[CLA](CLA.md), may also be distributed by the project owner under other
licenses.
