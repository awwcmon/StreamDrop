import AppKit
import Combine
import Foundation

@MainActor
final class DownloadStore: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var destinationURL: URL {
        didSet { persist() }
    }
    @Published var maxConcurrentDownloads: Int = 2 {
        didSet { persist(); schedule() }
    }
    @Published var notice: String?

    private let engine: DownloadEngine
    private let storageURL: URL
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var inspections: [UUID: Task<MediaInfo, Error>] = [:]
    private var metadata: [UUID: MediaInfo] = [:]
    private var lastProgressSave = Date.distantPast
    private var shuttingDown = false
    private var restoring = false

    var engineAvailable: Bool { engine.tools.available }
    var engineStatus: String { engine.tools.status }
    var isBusy: Bool { !jobs.isEmpty || !inspections.isEmpty }

    private struct SavedState: Codable {
        var items: [DownloadItem]
        var destination: String
        var concurrency: Int
    }

    init(storageURL: URL? = nil, engine: DownloadEngine = DownloadEngine()) {
        self.engine = engine
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = storageURL ?? support.appendingPathComponent("StreamDrop/queue.json")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        destinationURL = downloads.appendingPathComponent("StreamDrop", isDirectory: true)
        restore()
    }

    func inspect(urlString: String) async throws -> MediaInfo {
        let url = try validatedMediaURL(urlString)
        let id = UUID()
        let operation = Task { try await engine.inspect(url) }
        inspections[id] = operation
        defer { inspections.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    func enqueue(urlString: String, info: MediaInfo?, mode: OutputMode, quality: VideoQuality) throws {
        guard engineAvailable else { throw StreamDropError.engine(engineStatus) }
        let url = try validatedMediaURL(urlString)
        if items.contains(where: { $0.sourceURL == url.absoluteString && $0.mode == mode && $0.quality == quality && $0.phase != .completed && $0.phase != .failed }) {
            throw StreamDropError.engine("This link is already in your queue. Resume its existing download instead.")
        }
        if info?.isLive == true { throw StreamDropError.liveStream }
        let item = DownloadItem(
            sourceURL: url.absoluteString,
            title: info?.title ?? url.lastPathComponent.nonEmpty ?? url.host ?? "New download",
            site: info?.extractor ?? url.host ?? "Media",
            outputDirectory: destinationURL.path,
            mode: mode, quality: quality
        )
        if let info { metadata[item.id] = info }
        items.insert(item, at: 0)
        persist()
        schedule()
    }

    func pause(_ id: UUID) {
        guard let index = index(id), [.queued, .analyzing, .downloading, .processing].contains(items[index].phase) else { return }
        items[index].phase = .paused
        items[index].speed = nil
        items[index].eta = nil
        jobs[id]?.cancel()
        persist()
    }

    func resume(_ id: UUID) {
        guard let index = index(id), [.paused, .failed].contains(items[index].phase) else { return }
        items[index].phase = .queued
        items[index].errorMessage = nil
        persist()
        schedule()
    }

    func retry(_ id: UUID) { resume(id) }

    func remove(_ id: UUID) {
        jobs[id]?.cancel()
        items.removeAll { $0.id == id }
        metadata.removeValue(forKey: id)
        persist()
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let path = item.outputPath else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            notice = "This file has been moved or deleted: \(URL(fileURLWithPath: path).lastPathComponent)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func clearCompleted() {
        items.removeAll { $0.phase == .completed }
        persist()
    }

    func pauseAll() {
        for id in items.filter({ $0.phase.isActive || $0.phase == .queued }).map(\.id) { pause(id) }
    }

    func resumeAll() {
        for index in items.indices where items[index].phase == .paused {
            items[index].phase = .queued
            items[index].errorMessage = nil
        }
        persist()
        schedule()
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "New downloads will be saved here. Existing downloads keep their current folder."
        panel.directoryURL = destinationURL
        if panel.runModal() == .OK, let url = panel.url { destinationURL = url }
    }

    func shutdown() async {
        shuttingDown = true
        pauseAll()
        let tasks = Array(jobs.values)
        let lookups = Array(inspections.values)
        for task in tasks { task.cancel() }
        for task in lookups { task.cancel() }
        for task in tasks { await task.value }
        for task in lookups { _ = await task.result }
        persist()
    }

    private func schedule() {
        guard !shuttingDown, !restoring, engineAvailable else { return }
        let capacity = max(0, min(4, maxConcurrentDownloads) - jobs.count)
        let pending = items.filter { $0.phase == .queued && jobs[$0.id] == nil }.reversed().prefix(capacity)
        for item in pending {
            jobs[item.id] = Task { [weak self] in await self?.run(item.id) }
        }
    }

    private func run(_ id: UUID) async {
        defer {
            jobs.removeValue(forKey: id)
            persist()
            schedule()
        }
        do {
            try Task.checkCancellation()
            guard let position = index(id) else { return }
            if metadata[id] == nil {
                items[position].phase = .analyzing
                let info = try await engine.inspect(try validatedMediaURL(items[position].sourceURL))
                try Task.checkCancellation()
                guard let current = index(id) else { return }
                items[current].site = info.extractor
                metadata[id] = info
            }
            guard let current = index(id) else { return }
            items[current].phase = .downloading
            items[current].errorMessage = nil
            persist()
            let item = items[current]
            let path = try await engine.download(item) { [weak self] update in
                await self?.receive(update, id: id)
            }
            try Task.checkCancellation()
            guard let completed = index(id) else { return }
            items[completed].phase = .completed
            items[completed].outputPath = path
            items[completed].progress = 1
            items[completed].speed = nil
            items[completed].eta = nil
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber {
                items[completed].downloadedBytes = size.doubleValue
                items[completed].totalBytes = size.doubleValue
            }
            metadata.removeValue(forKey: id)
        } catch is CancellationError {
            if let position = index(id), items[position].phase != .queued {
                items[position].phase = .paused
                items[position].speed = nil
                items[position].eta = nil
            }
        } catch {
            guard let position = index(id) else { return }
            if !Task.isCancelled {
                items[position].phase = .failed
                items[position].errorMessage = error.localizedDescription
            }
            items[position].speed = nil
            items[position].eta = nil
        }
    }

    private func receive(_ update: DownloadUpdate, id: UUID) {
        guard let position = index(id), items[position].phase.isActive else { return }
        switch update {
        case .progress(let downloaded, let total, let speed, let eta):
            items[position].phase = .downloading
            items[position].downloadedBytes = downloaded
            items[position].totalBytes = total
            items[position].speed = speed
            items[position].eta = eta
            items[position].progress = total.map { $0 > 0 ? min(1, max(0, downloaded / $0)) : 0 } ?? 0
        case .processing:
            items[position].phase = .processing
            items[position].speed = nil
            items[position].eta = nil
        case .output(let path): items[position].outputPath = path
        }
        if Date().timeIntervalSince(lastProgressSave) >= 2 {
            lastProgressSave = Date()
            persist()
        }
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func restore() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        restoring = true
        defer { restoring = false }
        do {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: storageURL))
            destinationURL = URL(fileURLWithPath: state.destination, isDirectory: true)
            maxConcurrentDownloads = min(4, max(1, state.concurrency))
            items = state.items.map { item in
                var restored = item
                if item.phase.isActive || item.phase == .queued {
                    restored.phase = .paused
                    restored.speed = nil
                    restored.eta = nil
                }
                return restored
            }
        } catch {
            let backup = storageURL.deletingLastPathComponent().appendingPathComponent("queue-unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: storageURL, to: backup)
                notice = "The saved queue could not be read. A copy was kept at \(backup.path)."
            } catch {
                notice = "The saved queue could not be read or backed up: \(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        guard !restoring else { return }
        let state = SavedState(items: items, destination: destinationURL.path, concurrency: maxConcurrentDownloads)
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: storageURL, options: .atomic)
        } catch { notice = "The queue could not be saved: \(error.localizedDescription)" }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
