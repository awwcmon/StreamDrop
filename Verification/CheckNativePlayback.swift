import AVFoundation
import Foundation

@main
struct NativePlaybackCheck {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
            for row in rows where row["status"] as? String == "passed" {
                guard let output = row["output"] as? String else { continue }
                let asset = AVURLAsset(url: URL(fileURLWithPath: output))
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                let site = row["site"] as? String ?? "?"
                print("\(site)\tnative_playable=\(playable)\tduration=\(duration.seconds)")
            }
        }
    }
}
