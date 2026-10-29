# Credits

Third-party content and code bundled with Frontport, with its source and license.

## Platform photos

The console photos in `App/Resources/Assets.xcassets/Platforms` are from
Wikimedia Commons, scaled to 960 pixels wide: four by Evan-Amos (Vanamo Media)
and the PC by several photographers. They are in the public domain, so they
need no attribution; this file records where they came from.

| File | Source |
|---|---|
| `n64.jpg` | [N64-Console-Set.jpg](https://commons.wikimedia.org/wiki/File:N64-Console-Set.jpg) |
| `snes.jpg` | [SNES-Mod1-Console-Set.jpg](https://commons.wikimedia.org/wiki/File:SNES-Mod1-Console-Set.jpg) |
| `ps2.jpg` | [Sony-PlayStation-2-30001-wController-L.jpg](https://commons.wikimedia.org/wiki/File:Sony-PlayStation-2-30001-wController-L.jpg) |
| `switch.jpg` | [Nintendo-Switch-Console-Docked-wJoyConRB.jpg](https://commons.wikimedia.org/wiki/File:Nintendo-Switch-Console-Docked-wJoyConRB.jpg) |
| `dos.jpg` | [IBM PC XT (transparent).png](https://commons.wikimedia.org/wiki/File:IBM_PC_XT_(transparent).png), DigitalIceAge's composite of photos by Hidalgo944, Fried Dough and FA2010, also public domain, put on white |

The consoles and computers, and the names and logos on them, belong to Nintendo, Sony and IBM.
See [Third-party names and content](TRADEMARKS.md#third-party-names-and-content).

## Platform icons

The controller icons in `App/Resources/Assets.xcassets/PlatformIcons` are from
the FlatUI theme in [RetroArch's assets](https://github.com/libretro/retroarch-assets)
by the libretro contributors, at commit `d9f9690`, under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Frontport removed
their editor metadata. FlatUI has no PlayStation 2 icon, so `ps2.svg` is its
PlayStation pad in darker colours, with two analog sticks Frontport added. The
drawings are otherwise unchanged. FlatUI has no Switch icon either, so `switch.svg` is
Frontport's own drawing in FlatUI's colours, under Frontport's license. `dos.svg`
leaves out its `C:\DOS>` prompt text, which asset catalogs don't draw, and has a
cursor in its place.

| File | Source |
|---|---|
| `n64.svg` | [`src/xmb/flatui/Nintendo - Nintendo 64.svg`](https://github.com/libretro/retroarch-assets/blob/d9f969054dc7fbb6fa89519036d2b971e0855b51/src/xmb/flatui/Nintendo%20-%20Nintendo%2064.svg) |
| `snes.svg` | [`src/xmb/flatui/Nintendo - Super Nintendo Entertainment System.svg`](https://github.com/libretro/retroarch-assets/blob/d9f969054dc7fbb6fa89519036d2b971e0855b51/src/xmb/flatui/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System.svg) |
| `dos.svg` | [`src/xmb/flatui/DOS.svg`](https://github.com/libretro/retroarch-assets/blob/d9f969054dc7fbb6fa89519036d2b971e0855b51/src/xmb/flatui/DOS.svg), without its prompt text |
| `ps2.svg` | [`src/xmb/flatui/Sony - PlayStation.svg`](https://github.com/libretro/retroarch-assets/blob/d9f969054dc7fbb6fa89519036d2b971e0855b51/src/xmb/flatui/Sony%20-%20PlayStation.svg), recoloured, with sticks added |

CC BY 4.0 needs this credit where people see the icons, so the Catalog credits
RetroArch too.

## Code

| Component | Source | License |
|---|---|---|
| Sparkle 2.10.1, which updates Frontport | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle), linked through Swift Package Manager | MIT, with bsdiff, sais-lite and ed25519 under their own licenses |

The app carries Sparkle's license, external licenses included, as
`Contents/Resources/Sparkle-LICENSE.txt`, from
[`App/Resources/Licenses/Sparkle-LICENSE.txt`](App/Resources/Licenses/Sparkle-LICENSE.txt).
