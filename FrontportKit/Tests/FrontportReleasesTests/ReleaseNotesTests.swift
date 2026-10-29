import Foundation
import Testing

@testable import FrontportReleases

@Suite struct ReleaseNotesTests {
    // MARK: Release notes as upstream writes them

    @Test(arguments: [
        (
            NotesFixtures.buttons,
            "Small patch release after feedback on 2.4.0. Fixes two crashes, a few typos and a stuck save menu, and "
                + "tidies up the new controller settings, which matters most for speedrunners."
        ),
        (
            NotesFixtures.zelda64Recomp,
            "Hotfix for an issue that caused bad frame pacing on some multi-monitor setups."
        ),
        (
            NotesFixtures.twoShip,
            "Don't skip moon crash cutscene if we detect the player is trying 4th day glitch. Restore 2s save "
                + "delay when voiding out talking to an owl statue (for glitches)."
        ),
        (
            NotesFixtures.highlights,
            "Added a new harbour track and reworked its lighting. Implemented smarter computer racers, including "
                + "better item use and fewer crashes into walls. Added a lap timer and a ruleset editor."
        ),
    ])
    func summarizesUpstreamNotes(_ notes: String, _ expected: String) {
        #expect(ReleaseNotes.summary(notes) == expected)
        // GitHub serves bodies with CRLF line endings.
        #expect(ReleaseNotes.summary(notes.replacingOccurrences(of: "\n", with: "\r\n")) == expected)
    }

    @Test(arguments: [40, 80, 120, 220, 400])
    func staysWithinTheLimit(_ limit: Int) {
        for notes in [NotesFixtures.buttons, NotesFixtures.zelda64Recomp, NotesFixtures.twoShip, NotesFixtures.highlights] {
            let summary = ReleaseNotes.summary(notes, limit: limit)
            #expect(!summary.isEmpty)
            #expect(summary.count <= limit)
        }
    }

    @Test func prefersWholeSentences() {
        #expect(
            ReleaseNotes.summary(NotesFixtures.buttons, limit: 80)
                == "Small patch release after feedback on 2.4.0.")
    }

    @Test func cutsAtAWordWhenNoSentenceFits() {
        let summary = ReleaseNotes.summary(NotesFixtures.buttons, limit: 40)
        #expect(summary == "Small patch release after feedback on…")
    }

    @Test func leavesOutBoilerplate() {
        for notes in [NotesFixtures.buttons, NotesFixtures.twoShip, NotesFixtures.highlights] {
            let summary = ReleaseNotes.summary(notes, limit: 10_000)
            for boilerplate in ["What's Changed", "Full Changelog", "first contribution", "Download", "http", "@", "<"] {
                #expect(!summary.contains(boilerplate), "\(boilerplate) in \(summary)")
            }
        }
    }

    // MARK: Markdown

    @Test func stripsInlineMarkdown() {
        let notes = """
            Adds **bold** and *italic* and _under_ score, `code`, ~~gone~~ text, a [link](https://example.com),
            an image ![shot](https://example.com/a.png), <https://example.com> and snake_case_name &amp; more :tada:
            """
        #expect(
            ReleaseNotes.summary(notes, limit: 1000)
                == "Adds bold and italic and under score, code, gone text, a link, an image, and snake_case_name & more.")
    }

    @Test func skipsHeadingsHTMLAndCode() {
        let notes = """
            # Dewey Bravo
            <img width="1337"
                 alt="Logo" src="https://example.com/logo.png" />
            <!-- release checklist: bump version -->

            ```sh
            ./build.sh --release
            ```

            | Platform | File |
            |---|---|
            | Mac | SoH-Mac.zip |

            Changes
            -------
            Fixes the water temple.
            """
        #expect(ReleaseNotes.summary(notes) == "Fixes the water temple.")
    }

    @Test func skipsBoilerplateSections() {
        let notes = """
            ## Downloads
            Grab the Mac build below.

            ## Setup Guide
            Put your ROM next to the app.

            ## Highlights
            New title screen.

            ## New Contributors
            * @someone made their first contribution in https://github.com/o/r/pull/1

            **Full Changelog**: https://github.com/o/r/compare/1.0...1.1
            """
        #expect(ReleaseNotes.summary(notes) == "New title screen.")
    }

    @Test func dropsShortLabels() {
        #expect(ReleaseNotes.summary("1.2.2 Changelog:\n* Fixed audio crackling") == "Fixed audio crackling.")
    }

    @Test func noticesAndDetailsAreFallbacks() {
        let notes = """
            > [!NOTE]
            Your saves are kept between versions.

            <details><summary>All changes</summary>

            - Faster loading

            </details>

            Adds widescreen.
            """
        #expect(ReleaseNotes.summary(notes) == "Adds widescreen.")
        let onlyNotice = "> [!WARNING]\n> Back up your saves first!"
        #expect(ReleaseNotes.summary(onlyNotice) == "Back up your saves first!")
    }

    @Test func fallsBackToGeneratedPullRequestTitles() {
        let notes = """
            ## What's Changed
            * Fix crash on boot by @alice in https://github.com/o/r/pull/12
            * Add `--fullscreen` flag by @dependabot[bot] in #13

            **Full Changelog**: https://github.com/o/r/compare/1.0...1.1
            """
        #expect(ReleaseNotes.summary(notes) == "Fix crash on boot. Add --fullscreen flag.")
    }

    @Test func emptyOrBoilerplateOnlyNotesHaveNoSummary() {
        #expect(ReleaseNotes.summary("") == "")
        #expect(ReleaseNotes.summary("**Full Changelog**: https://github.com/o/r/compare/1.0...1.1") == "")
        #expect(ReleaseNotes.summary("Anything", limit: 0) == "")
    }
}
