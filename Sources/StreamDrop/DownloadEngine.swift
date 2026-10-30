import Foundation

struct EngineTools {
    var downloader: URL?
    var ffmpeg: URL?
    var worker: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment, worker: URL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL) {
        self.worker = worker
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"] + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        func locate(_ name: String) -> URL? {
            directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        downloader = locate("yt-dlp")
        ffmpeg = locate("ffmpeg")
    }
    var available: Bool { downloader != nil && ffmpeg != nil }
    var status: String {
        if downloader == nil { return "yt-dlp is missing. Run: brew install yt-dlp ffmpeg" }
        if ffmpeg == nil { return "FFmpeg is missing. Run: brew install ffmpeg" }
        return "yt-dlp and FFmpeg are ready"
    }
}

enum DownloadUpdate: Sendable {
    case progress(downloaded: Double, total: Double?, speed: Double?, eta: Double?)
    case processing
    case output(String)
}

struct DownloadEngine {
    let tools: EngineTools

    init(tools: EngineTools = EngineTools()) { self.tools = tools }

    static let commonArguments = [
        "--ignore-config", "--no-playlist", "--no-colors", "--no-cache-dir",
        "--socket-timeout", "20", "--retries", "2", "--fragment-retries", "2"
    ]

    func inspect(_ url: URL) async throws -> MediaInfo {
        guard let executable = tools.downloader else { throw StreamDropError.missingTool("yt-dlp") }
        let command = ManagedCommand(worker: tools.worker)
        return try await command.untilExit {
            var output = ""
            var errors = ""
            var status: Int32 = -1
            for try await event in command.events(executable: executable, arguments: Self.commonArguments + ["--dump-single-json", "--skip-download", "--", url.absoluteString]) {
                try Task.checkCancellation()
                switch event {
                case .stdout(let line):
                    guard output.utf8.count + line.utf8.count < 8 * 1024 * 1024 else {
                        command.cancel()
                        throw StreamDropError.engine("The media response is too large to process.")
                    }
                    output += line
                case .stderr(let line): errors = String((errors + line + "\n").suffix(6000))
                case .exited(let code): status = code
                }
            }
            guard status == 0 else { throw StreamDropError.engine(Self.errorMessage(errors, status: status)) }
            return try Self.decodeMetadata(Data(output.utf8), fallbackURL: url)
        }
    }

    static func decodeMetadata(_ data: Data, fallbackURL: URL) throws -> MediaInfo {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else {
            throw StreamDropError.engine("No downloadable media was found at this link.")
        }
        if object["is_live"] as? Bool == true || object["live_status"] as? String == "is_upcoming" {
            throw StreamDropError.liveStream
        }
        let formats = object["formats"] as? [[String: Any]] ?? []
        let heights = Set(formats.compactMap { format -> Int? in
            let height = (format["height"] as? NSNumber)?.intValue
            let width = (format["width"] as? NSNumber)?.intValue
            if let height, let width { return min(height, width) }
            return height
        }.filter { $0 > 0 })
        return MediaInfo(
            title: title,
            webpageURL: object["webpage_url"] as? String ?? fallbackURL.absoluteString,
            extractor: object["extractor_key"] as? String ?? object["extractor"] as? String ?? fallbackURL.host ?? "Media",
            duration: finiteNumber(object["duration"]),
            thumbnailURL: object["thumbnail"] as? String,
            availableHeights: heights.sorted(by: >),
            isLive: false
        )
    }

    func download(_ item: DownloadItem, onUpdate: @escaping @Sendable (DownloadUpdate) async -> Void) async throws -> String {
        guard let executable = tools.downloader else { throw StreamDropError.missingTool("yt-dlp") }
        guard let ffmpeg = tools.ffmpeg else { throw StreamDropError.missingTool("FFmpeg") }
        _ = try validatedMediaURL(item.sourceURL)
        let destination = URL(fileURLWithPath: item.outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".streamdrop-partials", isDirectory: true).appendingPathComponent(item.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let command = ManagedCommand(worker: tools.worker)
        return try await command.untilExit {
            var errors = ""
            var outputPath: String?
            var status: Int32 = -1
            for try await event in command.events(executable: executable, arguments: Self.downloadArguments(item, ffmpeg: ffmpeg, staging: staging)) {
                try Task.checkCancellation()
                switch event {
                case .stdout(let line):
                    if let update = Self.decodeUpdate(line) {
                        if case .output(let path) = update { outputPath = path }
                        await onUpdate(update)
                    }
                case .stderr(let line): errors = String((errors + line + "\n").suffix(6000))
                case .exited(let code): status = code
                }
            }
            guard status == 0 else { throw StreamDropError.engine(Self.errorMessage(errors, status: status)) }
            guard let outputPath else { throw StreamDropError.noOutput }
            let resultURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            guard resultURL.path.hasPrefix(destination.standardizedFileURL.path + "/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resultURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw StreamDropError.noOutput
            }
            if item.mode == .video {
                await onUpdate(.processing)
                try await normalizeVideo(at: resultURL, quality: item.quality, staging: staging)
            }
            return resultURL.path
        }
    }

    static func downloadArguments(_ item: DownloadItem, ffmpeg: URL, staging: URL) -> [String] {
        var arguments = commonArguments + [
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "--continue", "--no-overwrites", "--newline", "--progress", "--no-simulate",
            "--progress-delta", "0.2",
            "--progress-template", "download:SD_PROGRESS:%(progress)j",
            "--progress-template", "postprocess:SD_POST:%(progress)j",
            "--print", "after_move:SD_FILE:%(filepath)j",
            "--paths", "home:" + item.outputDirectory,
            "--paths", "temp:" + staging.path,
            "--output", item.filenameTemplate
        ]
        if item.mode == .audio {
            arguments += ["--format", "bestaudio/best", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"]
        } else {
            let resolution = item.quality == .best ? "res" : "res:\(item.quality.rawValue)"
            arguments += ["--format", "bv*+ba/b", "--format-sort", "\(resolution),vcodec:h264,acodec:aac", "--merge-output-format", "mp4", "--remux-video", "mp4"]
        }
        arguments += ["--", item.sourceURL]
        return arguments
    }

    func normalizeVideo(at url: URL, quality: VideoQuality, staging: URL) async throws {
        guard let ffmpeg = tools.ffmpeg else { throw StreamDropError.missingTool("FFmpeg") }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let data = try await capture(ffprobe, ["-v", "error", "-show_streams", "-of", "json", url.path])
        guard let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let width = (video["width"] as? NSNumber)?.intValue,
              let height = (video["height"] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw StreamDropError.engine("No video stream was found. Choose Audio to download an audio-only link.")
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let resize = quality != .best && min(width, height) > quality.rawValue
        let convertVideo = resize || video["codec_name"] as? String != "h264"
        let convertAudio = audio != nil && audio?["codec_name"] as? String != "aac"
        guard convertVideo || convertAudio else { return }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let converted = staging.appendingPathComponent("compatible.mp4")
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", convertVideo ? "libx264" : "copy"]
        if convertVideo {
            arguments += ["-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
        }
        if resize {
            let limit = quality.rawValue
            arguments += ["-vf", "scale=w='if(gte(iw,ih),-2,\(limit))':h='if(gte(iw,ih),\(limit),-2)',setsar=1"]
        }
        arguments += ["-c:a", convertAudio ? "aac" : "copy"]
        if convertAudio { arguments += ["-b:a", "192k"] }
        arguments += ["-movflags", "+faststart", converted.path]
        _ = try await capture(ffmpeg, arguments)
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: converted)
    }

    private func capture(_ executable: URL, _ arguments: [String]) async throws -> String {
        let command = ManagedCommand(worker: tools.worker)
        return try await command.untilExit {
            var output = ""
            var errors = ""
            var status: Int32 = -1
            for try await event in command.events(executable: executable, arguments: arguments) {
                try Task.checkCancellation()
                switch event {
                case .stdout(let line): output += line + "\n"
                case .stderr(let line): errors = String((errors + line + "\n").suffix(6000))
                case .exited(let code): status = code
                }
            }
            guard status == 0 else { throw StreamDropError.engine(Self.errorMessage(errors, status: status)) }
            return output
        }
    }

    static func decodeUpdate(_ line: String) -> DownloadUpdate? {
        if line.hasPrefix("SD_POST:") { return .processing }
        if line.hasPrefix("SD_FILE:"),
           let path = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(8).utf8), options: [.fragmentsAllowed]) as? String {
            return .output(path)
        }
        guard line.hasPrefix("SD_PROGRESS:"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(12).utf8)) as? [String: Any] else { return nil }
        if object["status"] as? String == "finished" { return .processing }
        guard let downloaded = finiteNumber(object["downloaded_bytes"]) else { return nil }
        return .progress(
            downloaded: max(0, downloaded),
            total: finiteNumber(object["total_bytes"]) ?? finiteNumber(object["total_bytes_estimate"]),
            speed: finiteNumber(object["speed"]), eta: finiteNumber(object["eta"])
        )
    }

    static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func errorMessage(_ value: String, status: Int32) -> String {
        let lines = value.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains("ERROR:") }
        let result = (errors.isEmpty ? Array(lines.suffix(4)) : errors).joined(separator: "\n")
        return result.isEmpty ? "The download engine exited with code \(status)." : result
    }
}
