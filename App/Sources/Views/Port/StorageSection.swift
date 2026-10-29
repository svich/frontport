import FrontportCore
import SwiftUI

/// Everything a Port keeps on disk, a row per folder with its size, what it holds and where it is: its Data and
/// Snapshots, its Installation and, for a source-built Port, the build folder kept for its next build. Each row offers
/// what removes it: Delete Data…, Uninstall… or Remove…. For a Port that isn't installed, it shows only while Data,
/// Snapshots or a build folder are left over, so they can still be removed.
struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ViewState.self) private var viewState
    let entry: CatalogEntry
    @State private var measurement: Measurement?

    /// Each folder's usage, nil when it isn't there, for one Port.
    private struct Measurement {
        var port: PortID
        var data: FileOperations.DiskUsage?
        var snapshots: FileOperations.DiskUsage?
        var installation: FileOperations.DiskUsage?
        var build: FileOperations.DiskUsage?
    }

    /// Measured again whenever the Port may have changed.
    private struct Key: Hashable {
        var port: PortID
        var revision: Int
    }

    var body: some View {
        let installation = model.survey.installation(entry.id)
        let isInstalled = installation != nil
        let measured = measurement.flatMap { $0.port == entry.id ? $0 : nil }
        let snapshots = model.snapshots[entry.id] ?? []
        let status = model.status(of: entry.id)
        let hasData = measured?.data != nil
        // A first install under way is using its build folder, not leaving it over.
        let hasBuild = measured?.build != nil && (isInstalled || model.activities[entry.id] == nil)
        // A stack rather than a Group, so the task runs while there's nothing to show.
        VStack(alignment: .leading, spacing: 0) {
            if isInstalled || hasData || !snapshots.isEmpty || hasBuild {
                GroupedSection(
                    "Storage", footer: footer(isInstalled: isInstalled, hasData: hasData || !snapshots.isEmpty, hasBuild: hasBuild)
                ) {
                    if isInstalled || hasData {
                        FolderRow(
                            "Data", size: dataSize(measured, isInstalled: isInstalled),
                            detail: "Progress, settings and the ROMs it keeps",
                            url: model.paths.data(for: entry.bundleId), exists: hasData
                        ) {
                            Button(status.title(.deleteData), role: .destructive) {
                                viewState.run(.deleteData, for: entry.id, in: model)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .foregroundStyle(.red)
                            .disabled(!status.allows(.deleteData))
                            .help(model.help(.deleteData, for: entry.id) ?? "")
                            .accessibilityIdentifier("data.delete")
                        }
                    }
                    if !snapshots.isEmpty {
                        FolderRow(
                            "Snapshots",
                            size: [Format.count(snapshots.count, "Snapshot"), measured?.snapshots.map { Format.bytes($0.allocated) }]
                                .compactMap { $0 }.joined(separator: " · "),
                            detail: "Copies of Data from before each change of Release, sharing its space until it changes",
                            url: model.paths.snapshots(for: entry.id), exists: measured?.snapshots != nil
                        ) {
                            EmptyView()
                        }
                    }
                    if let installation {
                        FolderRow(
                            "Installation", size: measured.map { $0.installation.map { Format.bytes($0.allocated) } ?? "Missing" },
                            detail: appDetail(previous: installation.previous),
                            url: model.paths.library(for: entry.id), exists: measured?.installation != nil
                        ) {
                            Button(status.title(.uninstall)) { viewState.run(.uninstall, for: entry.id, in: model) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .disabled(!status.allows(.uninstall))
                                .help(model.help(.uninstall, for: entry.id) ?? "")
                                .accessibilityIdentifier("data.uninstall")
                        }
                    }
                    if hasBuild || (isInstalled && entry.isSourceBuilt) {
                        FolderRow(
                            "Build folder", size: buildSize(measured),
                            detail: "Source and libraries the next build reuses, so it needn’t start from scratch",
                            url: model.paths.builds(for: entry.id), exists: hasBuild
                        ) {
                            if hasBuild {
                                Button(status.title(.removeBuildFolder)) {
                                    viewState.run(.removeBuildFolder, for: entry.id, in: model)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .disabled(!status.allows(.removeBuildFolder))
                                .help(model.help(.removeBuildFolder, for: entry.id) ?? "")
                                .accessibilityIdentifier("storage.removeBuildFolder")
                            }
                        }
                    }
                }
            }
        }
        .task(id: Key(port: entry.id, revision: model.revision(of: entry.id))) {
            if !isInstalled { await model.loadHistory(for: entry.id) }
            let folders = [
                model.paths.data(for: entry.bundleId), model.paths.snapshots(for: entry.id),
                model.paths.library(for: entry.id), model.paths.builds(for: entry.id),
            ]
            let usage = await Task.detached(priority: .utility) {
                folders.map { try? FileOperations.usage(of: $0) }
            }.value
            measurement = Measurement(
                port: entry.id, data: usage[0], snapshots: usage[1], installation: usage[2], build: usage[3])
        }
    }

    private func footer(isInstalled: Bool, hasData: Bool, hasBuild: Bool) -> String {
        if isInstalled {
            let removed = hasBuild ? "the Installation, the build folder and run logs" : "the Installation and run logs"
            return "Uninstall removes \(removed), and keeps Data and Snapshots. Delete Data removes both."
        }
        let data = hasData ? "Left from when \(entry.name) was installed. Installing it again picks up where you left off." : nil
        let build = hasBuild ? "Frontport removes the build folder, left from an install that didn’t finish, the next time it opens." : nil
        return [data, build].compactMap { $0 }.joined(separator: " ")
    }

    private func dataSize(_ measured: Measurement?, isInstalled: Bool) -> String? {
        guard let measured else { return nil }
        guard let data = measured.data else { return isInstalled ? "Nothing yet: it’s created on first launch" : "None" }
        return Format.bytes(data.allocated)
    }

    private func appDetail(previous: Release?) -> String {
        let current = entry.buildAssets == nil ? "The installed Release" : "The installed Release and its Build Assets"
        return previous.map { "\(current), and \($0.version) for Rollback" } ?? current
    }

    private func buildSize(_ measured: Measurement?) -> String? {
        guard let measured else { return nil }
        guard let build = measured.build else { return "None: the next build starts from scratch" }
        // Clones share their blocks, such as an extracted game cloned into the Build Assets: removing the folder
        // frees only what nothing else shares.
        let shared = build.allocated - build.unshared
        guard shared >= max(build.allocated / 10, 10 << 20) else { return Format.bytes(build.allocated) }
        return "\(Format.bytes(build.allocated)) · removing it frees \(Format.bytes(build.unshared))"
    }
}

/// One folder: its name and size, what it holds, and Open, which shows it in Finder, with its path on hover.
private struct FolderRow<Action: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    /// Nil while it's measured.
    let size: String?
    let detail: String
    let url: URL
    let exists: Bool
    @ViewBuilder let action: Action

    init(
        _ title: String, size: String?, detail: String, url: URL, exists: Bool, @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.size = size
        self.detail = detail
        self.url = url
        self.exists = exists
        self.action = action()
    }

    var body: some View {
        GroupedRow {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(title)
                    Text(" · \(size ?? "Measuring…")").foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            // Open last, so it lines up from row to row.
            HStack(spacing: 8) {
                action
                Button("Open") { model.openFolder(url) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!exists)
                    .help(path)
            }
        }
    }

    /// Abbreviated from the home folder: "~/Library/Containers/…/Data".
    private var path: String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
