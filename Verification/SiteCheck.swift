import Foundation

struct SiteCase: Codable, Sendable {
    var site: String
    var url: String
    var mode: String
    var source: String
    var quality: Int?
}

struct SiteResult: Codable, Sendable {
    var site: String
    var url: String
    var source: String
    var mode: String
    var requestedQuality: Int?
    var status = "started"
    var phase = "metadata"
    var title: String?
    var extractor: String?
    var duration: Double?
    var resolutions: [Int]?
    var elapsed: Double = 0
    var output: String?
    var bytes: Int64?
    var mediaProbe: String?
    var error: String?
}

enum SiteCheckError: LocalizedError {
    case timeout(String), tool(String)
    var errorDescription: String? {
        switch self {
        case .timeout(let phase): return "Test deadline exceeded during \(phase)"
        case .tool(let output): return output
        }
    }
}

func bounded<T: Sendable>(seconds: Double, phase: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SiteCheckError.timeout(phase)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func emit(_ value: some Encodable) {
    if let data = try? JSONEncoder().encode(value) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

func commandOutput(_ executable: String, _ arguments: [String], worker: URL) async throws -> String {
    let command = ManagedCommand(worker: worker)
    return try await command.untilExit {
        var text = ""
        var status: Int32 = -1
        for try await event in command.events(executable: URL(fileURLWithPath: executable), arguments: arguments) {
            switch event {
            case .stdout(let line), .stderr(let line): text += line + "\n"
            case .exited(let code): status = code
            }
        }
        guard status == 0 else { throw SiteCheckError.tool("exit \(status): \(text)") }
        return text
    }
}

@main
struct SiteCheck {
    static func main() async throws {
        EngineWorker.runIfRequested()
        guard CommandLine.arguments.count == 3 else {
            print("Usage: site-check cases.json new-output-directory")
            return
        }
        let cases = try JSONDecoder().decode([SiteCase].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tools = EngineTools()
        let engine = DownloadEngine(tools: tools)
        var results: [SiteResult] = []
        await withTaskGroup(of: SiteResult.self) { group in
            var pending = cases.makeIterator()
            for _ in 0..<3 {
                if let item = pending.next() { group.addTask { await check(item, root: root, engine: engine) } }
            }
            while let result = await group.next() {
                results.append(result)
                emit(result)
                if let item = pending.next() { group.addTask { await check(item, root: root, engine: engine) } }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results.sorted { $0.site < $1.site }).write(to: root.appendingPathComponent("report.json"), options: .atomic)
        emit(["summary": "\(results.filter { $0.status == "passed" }.count)/\(results.count) fully downloaded and decoded", "report": root.appendingPathComponent("report.json").path])
    }

    static func check(_ sample: SiteCase, root: URL, engine: DownloadEngine) async -> SiteResult {
        let start = Date()
        let quality = VideoQuality(rawValue: sample.quality ?? 480) ?? .p480
        var result = SiteResult(site: sample.site, url: sample.url, source: sample.source, mode: sample.mode, requestedQuality: sample.mode == "video" ? quality.rawValue : nil)
        emit(["site": sample.site, "event": "metadata_started", "url": sample.url])
        do {
            let url = try validatedMediaURL(sample.url)
            let info = try await bounded(seconds: 60, phase: "metadata") { try await engine.inspect(url) }
            result.title = info.title
            result.extractor = info.extractor
            result.duration = info.duration
            result.resolutions = info.availableHeights
            if let duration = info.duration, duration > 240 {
                result.status = "sample_too_long"
                result.error = "Sample is longer than the 240-second test limit; choose another public link"
            } else {
                result.phase = "download"
                emit(["site": sample.site, "event": "download_started", "title": info.title])
                let destination = root.appendingPathComponent(sample.site, isDirectory: true)
                let item = DownloadItem(sourceURL: sample.url, title: info.title, site: info.extractor, outputDirectory: destination.path, mode: sample.mode == "audio" ? .audio : .video, quality: quality)
                let path = try await bounded(seconds: 180, phase: "download") {
                    try await engine.download(item, onUpdate: { _ in })
                }
                result.output = path
                result.bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
                result.phase = "verification"
                let probe = engine.tools.ffmpeg!.deletingLastPathComponent().appendingPathComponent("ffprobe").path
                result.mediaProbe = try await bounded(seconds: 20, phase: "ffprobe") {
                    try await commandOutput(probe, ["-v", "error", "-show_entries", "format=duration,size:stream=codec_name,codec_type,width,height", "-of", "json", path], worker: engine.tools.worker)
                }
                _ = try await bounded(seconds: 90, phase: "full_decode") {
                    try await commandOutput(engine.tools.ffmpeg!.path, ["-nostdin", "-hide_banner", "-v", "error", "-xerror", "-i", path, "-f", "null", "-"], worker: engine.tools.worker)
                }
                result.phase = "complete"
                result.status = "passed"
            }
        } catch {
            result.status = "failed"
            result.error = error.localizedDescription
        }
        result.elapsed = Date().timeIntervalSince(start)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: root.appendingPathComponent(sample.site + ".json"), options: .atomic)
        }
        return result
    }
}
