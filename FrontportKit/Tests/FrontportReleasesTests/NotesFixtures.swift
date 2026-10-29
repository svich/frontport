// Release notes bodies. zelda64Recomp (GPL-3.0) and twoShip (CC0) were fetched from the GitHub API on 2026-10-24
// and are kept verbatim; buttons and highlights are written for these tests, since the projects whose layout they
// follow have no license. GitHub serves bodies with CRLF line endings; Swift literals normalize to LF, so tests also
// feed them back with CRLF.

enum NotesFixtures {
    /// Written for these tests in the layout of HarbourMasters' releases (Shipwright 9.3.1): download buttons as
    /// pictures, a setup guide link, a Changes paragraph without its final full stop, and the pull requests folded away.
    static let buttons = #"""
# Download
<a href="https://github.com/example/port/releases/download/2.4.1/Port-Win64.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/example/assets/windows-dark.png">
    <img alt="Windows" src="https://github.com/example/assets/windows.png">
  </picture>
</a>
<a href="https://github.com/example/port/releases/download/2.4.1/Port.appimage">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/example/assets/linux-dark.png">
    <img alt="Linux / Steam Deck" src="https://github.com/example/assets/linux.png">
  </picture>
</a>
<a href="https://github.com/example/port/releases/download/2.4.1/Port-Mac.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/example/assets/mac-dark.png">
    <img alt="macOS" src="https://github.com/example/assets/mac.png">
  </picture>
</a>

## Setup Guide
https://example.com/setup-guide

## Changes
Small patch release after feedback on 2.4.0. Fixes two crashes, a few typos and a stuck save menu, and tidies up the new controller settings, which matters most for speedrunners

## What's Changed
<details>

* Fix crash when opening the map during a cutscene by @alice in https://github.com/example/port/pull/101
* Fix typos in the options menu by @bob in https://github.com/example/port/pull/102
* Keep the save menu from sticking after a reset by @alice in https://github.com/example/port/pull/103
* [Bugfix] Restore the controller hint text by @carol in https://github.com/example/port/pull/104
* Pin the engine's maintenance branch by @dave in https://github.com/example/port/pull/105

</details>

**Full Changelog**: https://github.com/example/port/compare/2.4.0...2.4.1
"""#

    /// Zelda64Recomp/Zelda64Recomp v1.2.2
    static let zelda64Recomp = #"""
1.2.2 Changelog:
* Hotfix for an issue that caused bad frame pacing on some multi-monitor setups.

> [!NOTE]
Wondering about your save data when upgrading? Don't worry! Your save data is stored separately to the game itself. You can overwrite your old version and your save data will still be there, completely intact, and will work on the new version.

> [!NOTE]  
> **Intel GPU users:** Using outdated Intel drivers may cause the game to crash or cause graphical glitches. Please make sure your drivers are up-to-date before playing.
>
> [Intel HD 11th+ Gen/Intel Arc/Iris Xe](https://www.intel.com/content/www/us/en/download/785597/intel-arc-iris-xe-graphics-windows.html)
> [Intel HD 7th-10th Gen](https://www.intel.com/content/www/us/en/download/776137/intel-7th-10th-gen-processor-graphics-windows.html)
> [Intel HD 6th Gen](https://www.intel.com/content/www/us/en/download/762755/intel-6th-10th-gen-processor-graphics-windows.html)
>
> Do not use your operating system or driver suite to check for driver updates, sometimes these updates are not distributed by vendors. Always check Intel's website for the latest drivers.
"""#

    /// HarbourMasters/2ship2harkinian 5.0.1
    static let twoShip = #"""
![67180280-3c47-4c2e-a9a0-a086a57949dc](https://github.com/user-attachments/assets/a12851e2-1eb7-428c-973c-86fdfad73dd3)

# Download
<a href="https://github.com/HarbourMasters/2ship2harkinian/releases/download/5.0.1/2Ship-Battler-Bravo-Win64.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/HarbourMasters/Shipwright/assets/70942617/8e99955a-03a6-4663-97f2-39704f50a57f">
    <img alt="Windows" src="https://github.com/HarbourMasters/Shipwright/assets/70942617/57cdd3c0-ac25-4909-ac40-edaa68c2c698">
  </picture>
</a>
<a href="https://github.com/HarbourMasters/2ship2harkinian/releases/download/5.0.1/2Ship-Battler-Bravo-Linux.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/HarbourMasters/Shipwright/assets/70942617/32dad2f8-2669-406f-afb4-7264d7257f79">
    <img alt="Linux / Steam Deck" src="https://github.com/HarbourMasters/Shipwright/assets/70942617/74c2ec80-f769-4f54-a1b8-c9bc27e2473a">
  </picture>
</a>
<a href="https://github.com/HarbourMasters/2ship2harkinian/releases/download/5.0.1/2Ship-Battler-Bravo-Mac.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/HarbourMasters/Shipwright/assets/70942617/adacf7bf-19fd-4bdc-b7eb-59a69c52d8b5">
    <img alt="macOS" src="https://github.com/HarbourMasters/Shipwright/assets/70942617/73759976-597b-46c8-8d71-9dc9a2b0e1e3">
  </picture>
</a>

## Tweaks
- Don't skip moon crash cutscene if we detect the player is trying 4th day glitch
- Restore 2s save delay when voiding out talking to an owl statue (for glitches)
- Don't skip alien encounter cutscene when sun's song is active (for glitches) 
- Various randomizer logic fixes
- Skip to file select now applies after an Owl Save

## Bugs Fixed
- Fix crash when regenerating o2r with menus open.
- Fix Pause Menu songs being playable without ocarina buttons
- Fix editable hearts flags in save editor
- Fix for time moves when you move causing time to be frozen forever
- Fix tingle map & bombers notebook checks not being re-obtainable
- Fix for not removing old o2rs on MacOS
- Fix interpolation for Swamp Archery Enemies
- Fix interpolation for bubbles when swimming
- Fix item tracker tooltips being incorrect
- Fix edge case where owl feathers would despawn
- Fix blast mask check always being granted
- Fix pause buffer window pause loop when pause saving is enabled.
- Fix bug where masks given on moon remain unavailable when loading another save without playing Song of Time

## What's Changed
* Time Moves When You Move: fix saving zero time speed by @JordanLongstaff in https://github.com/HarbourMasters/2ship2harkinian/pull/1850
* Merge develop-keiichi->develop by @Eblo in https://github.com/HarbourMasters/2ship2harkinian/pull/1876
* Fix tingle map & bombers notebook checks not being re-obtainable by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1886
* Fix collected heart flags by @balloondude2 in https://github.com/HarbourMasters/2ship2harkinian/pull/1885
* Fix Song Items Logic by @mckinlee in https://github.com/HarbourMasters/2ship2harkinian/pull/1884
* Maybe fix wasapi teardown by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1879
* [Fix] Game crashes when menu engaged when regenerating OTR by @lightmanLP in https://github.com/HarbourMasters/2ship2harkinian/pull/1878
* properly remove all incompatible o2rs by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1882
* Fix interpolation for archery enemies and bubbles by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1889
* Fix tracker not handling incremented events and a small snowhead logic tweak by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1893
* Owl Statue skips to File Select by @JordanLongstaff in https://github.com/HarbourMasters/2ship2harkinian/pull/1854
* Fix two small item tracker quirks by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1895
* Don't skip moon crash CS if player is trying 4th day glitch by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1899
* Allow save delay when voiding out during owl save by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1901
* Don't skip aliens cutscene when suns song is active by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1900
* Fix pause buffer pause loop with pause save by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1902
* [Fix] Song of Time does not return Link to File Select by @JordanLongstaff in https://github.com/HarbourMasters/2ship2harkinian/pull/1897
* Fix blast mask check granted when killing/ignoring sakon by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1904
* Fix feathers despawning when voiding out by @garrettjoecox in https://github.com/HarbourMasters/2ship2harkinian/pull/1905
* Bump for Battler Bravo by @Eblo in https://github.com/HarbourMasters/2ship2harkinian/pull/1907
* Reset masksGivenOnMoon on file load by @JordanLongstaff in https://github.com/HarbourMasters/2ship2harkinian/pull/1908


**Full Changelog**: https://github.com/HarbourMasters/2ship2harkinian/compare/5.0.0...5.0.1
"""#

    /// Written for these tests in the layout of HarbourMasters' releases (SpaghettiKart 1.0.0): a logo, download
    /// buttons, highlights as a plain list, then every pull request and new contributor folded away.
    static let highlights = #"""

<img width="1337" height="122" alt="PortLogo" src="https://github.com/user-attachments/assets/logo" />


## Download

<a href="https://github.com/example/port/releases/download/1.0.0/port-windows.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/example/assets/windows-dark.png">
    <img alt="Windows" src="https://github.com/example/assets/windows.png">
  </picture>
</a>
<a href="https://github.com/example/port/releases/download/1.0.0/port-linux.zip">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://github.com/example/assets/linux-dark.png">
    <img alt="Linux / Steam Deck" src="https://github.com/example/assets/linux.png">
  </picture>
</a>

## What's Changed
* Added a new harbour track and reworked its lighting.
* Implemented smarter computer racers, including better item use and fewer crashes into walls.
* Added a lap timer and a ruleset editor.
* Smoothed frame interpolation for karts, menus and split screen.
* Reworked the camera, with a free camera for touring tracks.
* Fixed a wide range of item, multiplayer and battle mode bugs.

## Full Details
<details>

* Add the harbour track by @alice in https://github.com/example/port/pull/201
* Fix the L button changing the volume by @bob in https://github.com/example/port/pull/202
* Implement smarter computer racers by @alice in https://github.com/example/port/pull/203
* Add a lap timer by @carol in https://github.com/example/port/pull/204
* Build the macOS release as a Universal Binary by @dave in https://github.com/example/port/pull/205

## New Contributors
* @carol made their first contribution in https://github.com/example/port/pull/204
* @dave made their first contribution in https://github.com/example/port/pull/205

</details>

**Full Changelog**: https://github.com/example/port/compare/0.9.9...1.0.0
"""#
}
