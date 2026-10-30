import Foundation

enum DownloadPhase: String, Codable {
    case queued, analyzing, downloading, processing, paused, completed, failed

    var label: String { rawValue.capitalized }
    var isActive: Bool { [.analyzing, .downloading, .processing].contains(self) }
}

enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var title: String { self == .video ? "Video · MP4" : "Audio · MP3" }
    var symbol: String { self == .video ? "film" : "waveform" }
}

enum VideoQuality: Int, Codable, CaseIterable, Identifiable {
    case best = 0, p2160 = 2160, p1080 = 1080, p720 = 720, p480 = 480
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .best: return "Best available"
        case .p2160: return "Up to 4K"
        default: return "Up to \(rawValue)p"
        }
    }
}

struct MediaInfo: Equatable {
    var title: String
    var webpageURL: String
    var extractor: String
    var duration: Double?
    var thumbnailURL: String?
    var availableHeights: [Int]
    var isLive: Bool

    var durationLabel: String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        let seconds = Int(duration)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    var sourceURL: String
    var title: String
    var site: String
    var outputDirectory: String
    var mode: OutputMode
    var quality: VideoQuality
    var phase: DownloadPhase = .queued
    var progress: Double = 0
    var downloadedBytes: Double = 0
    var totalBytes: Double?
    var speed: Double?
    var eta: Double?
    var outputPath: String?
    var errorMessage: String?
    var createdAt = Date()

    var formatLabel: String {
        mode == .audio ? "MP3" : quality == .best ? "MP4 · Best" : "MP4 · ≤\(quality.rawValue)p"
    }
    var host: String { URL(string: sourceURL)?.host ?? site }
    var filenameTemplate: String {
        let forbidden = CharacterSet(charactersIn: "/\\:\n\r\t").union(.controlCharacters)
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String((cleaned.isEmpty ? "Download" : cleaned).prefix(80))
            .replacingOccurrences(of: "%", with: "%%")
        return "\(prefix) [\(id.uuidString.prefix(8).lowercased())].%(ext)s"
    }
}

enum StreamDropError: LocalizedError {
    case invalidURL, missingTool(String), engine(String), noOutput, cancelled, liveStream

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a complete http:// or https:// media link."
        case .missingTool(let tool): return "\(tool) was not found. Install it with Homebrew, then reopen StreamDrop."
        case .engine(let message): return message
        case .noOutput: return "The download ended without a media file. Try analyzing the link again."
        case .cancelled: return "The operation was cancelled."
        case .liveStream: return "Live streams are not supported in this version. Use a recorded video."
        }
    }
}

func validatedMediaURL(_ value: String) throws -> URL {
    let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, !input.contains(where: { $0.isWhitespace }),
          let components = URLComponents(string: input),
          let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          let url = components.url else { throw StreamDropError.invalidURL }
    return url
}

func byteLabel(_ bytes: Double?) -> String {
    guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, Double(Int64.max / 2))), countStyle: .file)
}

func etaLabel(_ seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
    let value = Int(min(seconds, 31_536_000))
    if value >= 3600 { return "\(value / 3600)h \(value / 60 % 60)m left" }
    if value >= 60 { return "\(value / 60)m \(value % 60)s left" }
    return "\(value)s left"
}
