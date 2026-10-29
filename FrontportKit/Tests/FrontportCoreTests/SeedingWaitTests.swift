import Testing
@testable import FrontportCore

/// When ROMs added for a Port are Seeded, with no clock, no running Port and no Library: just what happens, in order.
@Suite struct SeedingWaitTests {
    let port: PortID = "soh"

    @Test func aPortThatDoesNotRunSeedsNow() {
        var wait = SeedingWait()
        #expect(wait.requested(port, running: false) == .seed)
        #expect(!wait.isWaiting(port, running: false))
    }

    /// ROMs added while the Port runs wait for it to quit, then are requested again.
    @Test func aRunningPortsROMsWaitForItToQuit() {
        var wait = SeedingWait()
        let running = wait.requested(port, running: true)
        #expect(running == .wait && wait.isWaiting(port, running: true))
        let other = wait.ended(port, seeded: false, running: true)
        #expect(other == .wait, "another Activity ending changes nothing")

        let quit = wait.quit(port)
        let requested = wait.requested(port, running: false)
        let again = wait.quit(port)
        #expect(quit && requested == .seed)
        #expect(!again, "nothing waits once requested")
        #expect(!wait.isWaiting(port, running: true))
    }

    @Test func nothingWaitingMeansNothingToDo() {
        var wait = SeedingWait()
        let quit = wait.quit(port)
        let ended = wait.ended(port, seeded: false, running: false)
        #expect(!quit && ended == .wait)
        #expect(!wait.due(port, running: false) && !wait.isWaiting(port, running: true))
    }

    /// Right after a quit macOS may still list the Port, and the Library refuses: tried again after 1, 2, 4 and 8
    /// seconds, then the ROMs wait for the next quit, which brings every try back.
    @Test func aRefusalAfterAQuitIsTriedAgainLongerEachTime() {
        var wait = SeedingWait()
        var steps: [SeedingWait.Step] = []
        for _ in 0...SeedingWait.tries {
            wait.refused(port)
            steps.append(wait.ended(port, seeded: false, running: false))
        }
        #expect(steps == [
            .retry(after: .seconds(1)), .retry(after: .seconds(2)), .retry(after: .seconds(4)), .retry(after: .seconds(8)),
            .wait,
        ])
        #expect(wait.due(port, running: false), "still waiting, for the next quit or Try Again")
        #expect(!wait.due(port, running: true))

        let quit = wait.quit(port)
        wait.refused(port)
        let first = wait.ended(port, seeded: false, running: false)
        #expect(quit && first == .retry(after: .seconds(1)))
    }

    @Test func seedingStartsTheTriesOver() {
        var wait = SeedingWait()
        wait.refused(port)
        let retry = wait.ended(port, seeded: false, running: false)
        let requested = wait.requested(port, running: false)
        let seeded = wait.ended(port, seeded: true, running: false)
        #expect(retry == .retry(after: .seconds(1)) && requested == .seed && seeded == .wait)

        wait.refused(port)
        let again = wait.ended(port, seeded: false, running: false)
        #expect(again == .retry(after: .seconds(1)))
    }

    /// A refusal while the Port really runs waits for its quit rather than trying again.
    @Test func aRefusalWhileItRunsWaitsForTheQuit() {
        var wait = SeedingWait()
        wait.refused(port)
        let ended = wait.ended(port, seeded: false, running: true)
        #expect(ended == .wait && wait.isWaiting(port, running: true))
        #expect(!wait.due(port, running: true))
    }

    @Test func eachPortWaitsOnItsOwn() {
        var wait = SeedingWait()
        let running = wait.requested(port, running: true)
        let quit = wait.quit("starship")
        let other = wait.requested("starship", running: false)
        #expect(running == .wait && !quit && other == .seed)
        #expect(wait.isWaiting(port, running: true) && !wait.isWaiting("starship", running: true))
    }
}
