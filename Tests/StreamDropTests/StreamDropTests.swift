import AVFoundation
import XCTest
@testable import StreamDrop

final class StreamDropTests: XCTestCase {
    func testURLValidationRejectsLocalFilesCredentialsAndOptions() throws {
        for input in ["file:///etc/passwd", "--exec=touch test", "javascript:alert(1)", "https://user:secret@example.com/video", "https://example.com/a b", "", "https://"] {
            XCTAssertThrowsError(try validatedMediaURL(input), input)
        }
        XCTAssertEqual(try validatedMediaURL("  https://example.com/watch?v=a&list=b  ").absoluteString, "https://example.com/watch?v=a&list=b")
    }

    func testFilenameCannotEscapeDestinationOrInjectTemplate() {
        let item = DownloadItem(sourceURL: "https://example.com/video", title: "../../title %(id)s / live\nclip", site: "Test", outputDirectory: "/Downloads", mode: .video, quality: .p720)
        XCTAssertFalse(item.filenameTemplate.contains("/"))
        XCTAssertFalse(item.filenameTemplate.contains("\n"))
        XCTAssertTrue(item.filenameTemplate.contains("%%(id)s"))
        XCTAssertTrue(item.filenameTemplate.hasSuffix(".%(ext)s"))
    }

    func testProgressParsingWithUnknownTotalAndMalformedLines() {
        XCTAssertNil(DownloadEngine.decodeUpdate("an ordinary log line"))
        XCTAssertNil(DownloadEngine.decodeUpdate("SD_PROGRESS:not-json"))
        let unknown = DownloadEngine.decodeUpdate("SD_PROGRESS:{\"downloaded_bytes\":1024,\"total_bytes\":null,\"eta\":null,\"speed\":512}")
        guard case .progress(let bytes, let total, let speed, let eta) = unknown else { return XCTFail("Expected progress") }
        XCTAssertEqual(bytes, 1024)
        XCTAssertNil(total)
        XCTAssertEqual(speed, 512)
        XCTAssertNil(eta)
        let known = DownloadEngine.decodeUpdate("SD_PROGRESS:{\"downloaded_bytes\":2048,\"total_bytes_estimate\":4096,\"eta\":2}")
        guard case .progress(_, let estimate, _, _) = known else { return XCTFail("Expected estimated total") }
        XCTAssertEqual(estimate, 4096)
    }

    func testOutputJSONPreservesUnicodeAndSpaces() {
        let update = DownloadEngine.decodeUpdate("SD_FILE:\"/Downloads/视频 sample [123].mp4\"")
        guard case .output(let path) = update else { return XCTFail("Expected file path") }
        XCTAssertEqual(path, "/Downloads/视频 sample [123].mp4")
    }

    func testMetadataRejectsLiveAndDeduplicatesResolutions() throws {
        let url = URL(string: "https://example.com/watch")!
        let json = Data(#"{"title":"Example","duration":125,"formats":[{"height":1080},{"height":720},{"height":1080},{"height":null}]}"#.utf8)
        let result = try DownloadEngine.decodeMetadata(json, fallbackURL: url)
        XCTAssertEqual(result.availableHeights, [1080, 720])
        XCTAssertEqual(result.durationLabel, "2:05")
        XCTAssertThrowsError(try DownloadEngine.decodeMetadata(Data(#"{"title":"Live","is_live":true}"#.utf8), fallbackURL: url))
    }

    func testArgumentsSeparateURLAndIgnorePersonalConfig() {
        let item = DownloadItem(sourceURL: "https://example.com/watch?v=$(id)&x=a;b", title: "Sample", site: "Test", outputDirectory: "/Downloads/Media", mode: .video, quality: .p720)
        let arguments = DownloadEngine.downloadArguments(item, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), staging: URL(fileURLWithPath: "/Downloads/Media/.partial"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["--", item.sourceURL])
        XCTAssertTrue(arguments.contains("--ignore-config"))
        XCTAssertTrue(arguments.contains("--no-playlist"))
        XCTAssertTrue(arguments.contains("--continue"))
        XCTAssertTrue(arguments.contains("res:720,vcodec:h264,acodec:aac"))
        XCTAssertFalse(arguments.contains("--exec"))
    }

    @MainActor
    func testRestorePausesInterruptedJobsAndPreservesOriginalQueueDuringLoad() throws {
        let directory = try verificationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = directory.appendingPathComponent("queue.json")
        let item = DownloadItem(sourceURL: "https://example.com/video", title: "Paused sample", site: "Test", outputDirectory: directory.path, mode: .audio, quality: .best, phase: .downloading, progress: 0.42)
        let itemJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([item]))
        let data = try JSONSerialization.data(withJSONObject: ["items": itemJSON, "destination": directory.path, "concurrency": 3])
        try data.write(to: queue)
        let store = DownloadStore(storageURL: queue)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].phase, .paused)
        XCTAssertEqual(store.items[0].progress, 0.42)
        XCTAssertEqual(store.maxConcurrentDownloads, 3)
        XCTAssertEqual(try Data(contentsOf: queue), data)
    }

    @MainActor
    func testRealVideoAudioPauseResumeAndPersistence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["STREAMDROP_TEST_URL"], let worker = environment["STREAMDROP_TEST_WORKER"] else {
            throw XCTSkip("Set STREAMDROP_TEST_URL and STREAMDROP_TEST_WORKER for media integration checks")
        }
        let directory = try verificationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = DownloadEngine(tools: EngineTools(worker: URL(fileURLWithPath: worker)))
        XCTAssertTrue(engine.tools.available)
        var store = DownloadStore(storageURL: directory.appendingPathComponent("queue.json"), engine: engine)
        store.destinationURL = directory.appendingPathComponent("media", isDirectory: true)
        store.maxConcurrentDownloads = 1
        var media = try await store.inspect(urlString: address + "/sample.mp4")
        XCTAssertFalse(media.title.isEmpty)
        media.title = "Original title before website rename"
        try store.enqueue(urlString: address + "/slow.mp4", info: media, mode: .video, quality: .p720)
        let videoID = try XCTUnwrap(store.items.first?.id)
        try await waitUntil { store.items.first(where: { $0.id == videoID })?.downloadedBytes ?? 0 > 0 }
        store.pause(videoID)
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.items.first?.phase, .paused)
        let partials = FileManager.default.enumerator(atPath: store.destinationURL.appendingPathComponent(".streamdrop-partials").path)?.allObjects as? [String] ?? []
        XCTAssertTrue(partials.contains { $0.hasSuffix(".part") })
        await store.shutdown()
        store = DownloadStore(storageURL: directory.appendingPathComponent("queue.json"), engine: engine)
        store.resume(videoID)
        try store.enqueue(urlString: address + "/sample.mp4", info: media, mode: .audio, quality: .best)
        XCTAssertThrowsError(try store.enqueue(urlString: address + "/sample.mp4", info: media, mode: .audio, quality: .best))
        try await waitUntil { !store.items.contains { $0.phase.isActive || $0.phase == .queued } && !store.isBusy }
        XCTAssertEqual(store.items.filter { $0.phase == .completed }.count, 2, store.items.compactMap(\.errorMessage).joined(separator: "\n"))
        XCTAssertEqual(store.items.first(where: { $0.id == videoID })?.title, media.title)
        for item in store.items {
            let path = try XCTUnwrap(item.outputPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            XCTAssertTrue(path.hasSuffix(item.mode == .audio ? ".mp3" : ".mp4"))
            XCTAssertGreaterThan(item.downloadedBytes, 0)
        }
        let restored = DownloadStore(storageURL: directory.appendingPathComponent("queue.json"), engine: engine)
        XCTAssertEqual(restored.items.map(\.id), store.items.map(\.id))
        XCTAssertTrue(restored.items.allSatisfy { $0.phase == .completed })
        let paths = store.items.compactMap(\.outputPath)
        store.clearCompleted()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        do {
            _ = try await store.inspect(urlString: address + "/missing.mp4")
            XCTFail("404 must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("404"), error.localizedDescription) }
        await store.shutdown()
        print("INTEGRATION PASS: MP4, MP3, pause/Range resume, duplicate rejection, persistence, retain completed files, HTTP 404")
    }

    func testRealVP9ConversionAndPortraitQualityLimit() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["STREAMDROP_TEST_URL"], let worker = environment["STREAMDROP_TEST_WORKER"] else {
            throw XCTSkip("Run Verification/test_local.py for media conversion checks")
        }
        let directory = try verificationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = DownloadEngine(tools: EngineTools(worker: URL(fileURLWithPath: worker)))
        let item = DownloadItem(sourceURL: address + "/vp9.webm", title: "Portrait codec regression", site: "Local", outputDirectory: directory.path, mode: .video, quality: .p480)
        let output = try await engine.download(item, onUpdate: { _ in })
        let asset = AVURLAsset(url: URL(fileURLWithPath: output))
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(min(size.width, size.height), 480)
        XCTAssertGreaterThan(size.height, size.width)
        let descriptions = try await video.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)), kCMVideoCodecType_H264)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioDescriptions = try await audio.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(audioDescriptions.first)), kAudioFormatMPEG4AAC)
    }

    func testCancelReapsDescendantAfterRootHasExited() async throws {
        guard let worker = ProcessInfo.processInfo.environment["STREAMDROP_TEST_WORKER"] else {
            throw XCTSkip("Set STREAMDROP_TEST_WORKER to check process cancellation")
        }
        let command = ManagedCommand(worker: URL(fileURLWithPath: worker))
        let program = """
        import os, signal, time
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            time.sleep(12)
            os._exit(0)
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        print('READY', flush=True)
        time.sleep(12)
        """
        let start = Date()
        do {
            try await command.untilExit {
                for try await event in command.events(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-I", "-c", program]) {
                    if case .stdout("READY") = event { command.cancel() }
                }
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 50, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw StreamDropError.engine("Integration condition timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func verificationDirectory() throws -> URL {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/test-runs", isDirectory: true)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
