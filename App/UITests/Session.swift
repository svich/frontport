import AppKit
import FrontportCore
import XCTest

/// The real Debug app on its real services, over a fresh `FRONTPORT_ROOT`, with helpers that find controls by
/// the accessibility identifiers the app sets (see App/Sources/Components/TestIdentifiers.swift).
///
/// Port Data still lives in the real containers in `~/Library/Containers`, as it does for the app.
@MainActor
final class Session {
    let app = XCUIApplication()
    /// This session's scratch folder: the app's root, and files the test hands to the app.
    let scratch: URL
    var root: URL { scratch.appending(path: "root", directoryHint: .isDirectory) }
    /// The local server standing in for the Catalog and GitHub, if the session uses one instead of the real ones.
    let world: TestportWorld?

    private init(scratch: URL, world: TestportWorld?) {
        self.scratch = scratch
        self.world = world
    }

    // MARK: Launching

    /// Launches the app over an empty root and quits it, and removes the root, when the test ends. With a `world`,
    /// the app takes its Catalog and Releases from that local server instead of the real Catalog and GitHub.
    static func launch(_ test: XCTestCase, arguments: [String] = [], world: TestportWorld? = nil) throws -> Session {
        let scratch = Self.base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let session = Session(scratch: scratch, world: world)
        try FileManager.default.createDirectory(at: session.root, withIntermediateDirectories: true)
        if let world {
            try world.seedCatalog(in: session.root)
        } else {
            try session.restoreReleasesCache()
        }
        session.app.launchEnvironment["FRONTPORT_ROOT"] = session.root.path(percentEncoded: false)
        // The user's own defaults would otherwise pick the Library layout, and window state an earlier run left (such
        // as the snapshot driver's) could open the app with no window.
        session.app.launchArguments =
            ["-libraryLayout", "grid", "-ApplePersistenceIgnoreState", "YES"] + (world?.arguments ?? []) + arguments
        test.addTeardownBlock { @MainActor in session.close() }
        session.app.launch()
        session.waitForAny("screen.catalog", "screen.library", timeout: 60)
        return session
    }

    /// Quits and opens the app again over the same root.
    func relaunch() {
        app.terminate()
        app.launch()
        waitForAny("screen.catalog", "screen.library", timeout: 60)
    }

    /// Attaches the Port's run logs, and the files in `folders`, to a failed test's result before the root and
    /// the Port's Data are removed.
    func attachLogs(of port: String, from folders: [URL] = [], to test: XCTestCase) {
        test.addTeardownBlock { @MainActor in
            let runs = self.root.appending(path: "Logs/\(port)", directoryHint: .isDirectory)
            for folder in [runs] + folders {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
                for name in names.sorted() {
                    let file = folder.appending(path: name)
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let attachment = XCTAttachment(contentsOfFile: file)
                    attachment.name = "\(folder.lastPathComponent) \(name)"
                    attachment.lifetime = .deleteOnSuccess
                    test.add(attachment)
                }
            }
        }
    }

    private func close() {
        app.terminate()
        if world == nil { saveReleasesCache() }
        try? FileOperations.removeUntrusted(scratch)
    }

    /// Every session's scratch folder, and what they share.
    static let base = FileManager.default.temporaryDirectory.appending(path: "FrontportUITests", directoryHint: .isDirectory)

    /// GitHub answers kept between sessions, so each fresh root asks GitHub with ETags, which don't count against
    /// its rate limit of 60 requests an hour, and a session that hits the limit still has answers.
    private static let releasesCache = base.appending(path: "releases-cache", directoryHint: .isDirectory)
    private var releases: URL { root.appending(path: "Catalog/releases", directoryHint: .isDirectory) }

    private func restoreReleasesCache() throws {
        guard FileManager.default.fileExists(atPath: Self.releasesCache.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: releases.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.releasesCache, to: releases)
    }

    private func saveReleasesCache() {
        guard FileManager.default.fileExists(atPath: releases.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(at: Self.releasesCache)
        try? FileManager.default.copyItem(at: releases, to: Self.releasesCache)
    }

    // MARK: Finding

    /// The first element with this accessibility identifier, of any type.
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier(id)).firstMatch
    }

    /// Elements inside `scope` whose identifiers start with `prefix`.
    func elements(prefix: String, in scope: XCUIElement? = nil) -> [XCUIElement] {
        (scope ?? app).descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
    }

    private func identifier(_ id: String) -> NSPredicate { NSPredicate(format: "identifier == %@", id) }

    /// Waits for the element and fails the test if it doesn't appear.
    @discardableResult
    func wait(
        for id: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let element = element(id)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(id) didn't appear", file: file, line: line)
        return element
    }

    /// Waits for any of the elements and fails the test if none appears.
    func waitForAny(_ ids: String..., timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let found = waitUntil(timeout) { ids.contains { element($0).exists } }
        XCTAssertTrue(found, "None of \(ids) appeared", file: file, line: line)
    }

    func waitUntilGone(
        _ id: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line
    ) {
        let element = element(id)
        XCTAssertTrue(waitUntil(timeout) { !element.exists }, "\(id) didn't go away", file: file, line: line)
    }

    /// Polls `condition` until it holds or `timeout` passes.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval, poll: TimeInterval = 0.5, _ condition: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date.now >= deadline { return false }
            RunLoop.current.run(until: Date.now.addingTimeInterval(poll))
        }
    }

    // MARK: Acting

    /// Waits for the element to exist and be enabled, scrolls it into view and clicks it.
    @discardableResult
    func click(
        _ id: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let element = wait(for: id, timeout: timeout, file: file, line: line)
        XCTAssertTrue(waitUntil(timeout) { element.isEnabled }, "\(id) stayed disabled", file: file, line: line)
        click(element)
        return element
    }

    func click(_ element: XCUIElement) {
        // A Port's window, or macOS's report of one that crashed, may be in front, and a click on an inactive
        // window only brings it forward. Frontport may report itself in the foreground while a Port's late window
        // covers it.
        if app.state != .runningForeground { app.activate() }
        if !element.isHittable {
            app.activate()
            reveal(element)
        }
        element.click()
    }

    /// Scrolls the scroll area holding the element until all of it shows: one cut off at the edge counts as
    /// hittable, but a click on its hit point can miss.
    private func reveal(_ element: XCUIElement) {
        guard element.exists, !element.isHittable else { return }
        let area = app.scrollViews.containing(identifier(element.identifier)).firstMatch
        guard area.exists else { return }
        func shown() -> Bool { element.isHittable && area.frame.contains(element.frame) }
        for delta: CGFloat in [-150, 150] {
            for _ in 0..<20 where !shown() {
                area.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
    }

    /// Types into the sidebar's search field, replacing what's there.
    func search(_ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No search field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
    }

    var searchText: String {
        let field = app.searchFields.firstMatch
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// Waits for the Catalog's Platforms, which show once it's loaded.
    func waitForCatalog(file: StaticString = #filePath, line: UInt = #line) {
        scrollTo("catalog.platform.\(BundledCatalog.document.platforms.first?.id.rawValue ?? "")", in: "screen.catalog", file: file, line: line)
    }

    /// Scrolls a screen up and down until the element exists, and fails the test if it doesn't appear. A lazy grid
    /// makes its items only near the visible area, so one further down doesn't exist until scrolled to.
    @discardableResult
    func scrollTo(
        _ id: String, in screen: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let target = element(id)
        let area = wait(for: screen, file: file, line: line)
        let deadline = Date.now.addingTimeInterval(timeout)
        var delta: CGFloat = -200
        while !target.exists, Date.now < deadline {
            for _ in 0..<10 where !target.exists { area.scroll(byDeltaX: 0, deltaY: delta) }
            delta = -delta
        }
        XCTAssertTrue(target.exists, "\(id) didn't appear in \(screen)", file: file, line: line)
        return target
    }

    /// Finds a Port by searching and opens its store page from the result.
    func openStorePage(_ port: String, searching query: String, file: StaticString = #filePath, line: UInt = #line) {
        search(query)
        wait(for: "screen.search", file: file, line: line)
        click("catalog.card.\(port)", file: file, line: line)
        wait(for: "screen.store.\(port)", file: file, line: line)
        wait(for: "store.status", file: file, line: line)
    }

    /// Picks a section of the Port page in the toolbar picker: by the segment's identifier, else by its title.
    func selectTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        var segment = element("port.tab.\(title.lowercased())")
        if !segment.waitForExistence(timeout: 5) {
            let picker = element("port.tabs")
            let types = [XCUIElement.ElementType.radioButton, .button].map(\.rawValue)
            segment = (picker.exists ? picker : app).descendants(matching: .any)
                .matching(NSPredicate(
                    format: "elementType IN %@ AND (label == %@ OR title == %@)", types, title, title))
                .firstMatch
        }
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "No \(title) segment", file: file, line: line)
        click(segment)
    }

    /// A toggle's state, however the switch reports it.
    func isOn(_ toggle: XCUIElement) -> Bool {
        switch toggle.value {
        case let number as NSNumber: number.boolValue
        case let text as String: text == "1" || text.lowercased() == "true" || text.lowercased() == "on"
        default: false
        }
    }

    // MARK: Dialogs

    /// The confirmation or alert shown on the window, if one appears within `timeout`.
    func dialog(timeout: TimeInterval = 10) -> XCUIElement? {
        let candidates = [app.sheets.firstMatch, app.dialogs.firstMatch, app.alerts.firstMatch]
        var found: XCUIElement?
        waitUntil(timeout) {
            found = candidates.first(where: \.exists)
            return found != nil
        }
        return found
    }

    /// Requires a confirmation to be showing, clicks one of its buttons and waits for it to close.
    func answerDialog(_ button: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let dialog = dialog() else {
            XCTFail("No confirmation appeared before \(button)", file: file, line: line)
            return
        }
        let target = dialog.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", button, button)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "The confirmation has no \(button)", file: file, line: line)
        click(target)
        XCTAssertTrue(waitUntil(10) { !dialog.exists }, "The confirmation stayed open", file: file, line: line)
    }

    /// Waits for an install started from the store page to finish, failing with the alert's text if it fails.
    func waitForInstall(_ port: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let done = element("store.inLibrary")
        var failure: String?
        let finished = waitUntil(timeout, poll: 2) {
            if done.exists { return true }
            if let alert = [app.sheets.firstMatch, app.dialogs.firstMatch, app.alerts.firstMatch].first(where: \.exists) {
                failure = (try? strings(in: alert))?.joined(separator: " ") ?? "an alert"
                return true
            }
            return false
        }
        if let failure { XCTFail("Installing \(port) failed: \(failure)", file: file, line: line) }
        XCTAssertTrue(finished, "Installing \(port) didn't finish in \(Int(timeout)) s", file: file, line: line)
    }

    // MARK: Text

    /// What a text element shows: its value, else its label, else its children's, such as a text with a link.
    func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        if !element.label.isEmpty { return element.label }
        return ((try? strings(in: element, includingContent: true)) ?? []).joined(separator: " ")
    }

    /// Every label, title, value and placeholder in an element and its descendants, skipping text marked as
    /// Catalog or upstream content unless asked for it.
    func strings(in element: XCUIElement, includingContent: Bool = false) throws -> [String] {
        var result: [String] = []
        func collect(_ snapshot: any XCUIElementSnapshot) {
            // Marked text can hold its words in children, as selectable text does.
            guard includingContent || !snapshot.identifier.hasPrefix("content.") else { return }
            let value = snapshot.value as? String
            for text in [snapshot.label, snapshot.title, value, snapshot.placeholderValue] {
                if let text, !text.isEmpty { result.append(text) }
            }
            snapshot.children.forEach(collect)
        }
        collect(try element.snapshot())
        return result
    }

    /// Fails if Frontport's own wording in the window uses a word GLOSSARY.md says to avoid.
    func assertGlossaryWording(_ screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch
        let found = Glossary.violations(in: try strings(in: window))
        XCTAssertTrue(found.isEmpty, "\(screen) uses words GLOSSARY.md avoids: \(found)", file: file, line: line)
    }
}
