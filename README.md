# StreamDrop

A native macOS media downloader built with SwiftUI, yt-dlp, and FFmpeg.

Add a link, choose video or audio, and keep track of downloads in a persistent queue.

[中文说明](README.zh-CN.md)

## Features

- Native interface with drag-and-drop links and explicit clipboard paste
- Link analysis and media preview before downloading
- MP4 video with H.264/AAC compatibility processing; MP3 audio extraction
- Best available quality or a 4K, 1080p, 720p, or 480p limit
- Quality limits measured on the shorter edge, including portrait video
- Concurrent downloads, pause/resume, retry, and Finder reveal
- Queue persistence; interrupted jobs reopen paused
- Local processing without a StreamDrop account or backend service

Compatible video streams are copied; other codecs or oversized video are converted locally. Conversion can take time and uses CPU. Resuming depends on the source supporting range requests or resumable fragments.

## Requirements

- macOS 14 or newer
- Xcode with the Swift 6 toolchain to build
- Homebrew installations of yt-dlp and FFmpeg, including ffprobe
- Python 3 for the optional integration checks

```sh
brew install yt-dlp ffmpeg
```

Some yt-dlp extractors also require a JavaScript runtime such as Deno. Install it when the extractor's error asks for it:

```sh
brew install deno
```

StreamDrop looks for tools in `/opt/homebrew/bin`, `/usr/local/bin`, and the inherited `PATH`. The app does not bundle or automatically install these tools.

## Build and run

```sh
gh repo clone awwcmon/StreamDrop
cd StreamDrop
./build.sh
open build/StreamDrop.app
```

The script creates an app for the current Mac architecture and applies an ad-hoc signature. This is a local build, not an Apple-notarized distribution.

To install that build for your user:

```sh
mkdir -p "$HOME/Applications"
ditto build/StreamDrop.app "$HOME/Applications/StreamDrop.app"
```

Quit any existing StreamDrop instance before replacing its application bundle.

## Usage

1. Choose **Add Link**, **Paste Link**, or drop a URL into the window.
2. Select **Analyze** to load the media title and available resolutions.
3. Choose **Video · MP4** or **Audio · MP3**, set quality, and select **Download**.
4. Use the queue controls to pause, resume, retry, or reveal the resulting file.

`⌘N` opens the link dialog; `⇧⌘V` reads a link from the clipboard. Settings controls the destination folder and simultaneous download count.

The default output folder is `~/Downloads/StreamDrop`. Queue state is stored in `~/Library/Application Support/StreamDrop/queue.json`, including source URLs and file paths. Download fragments are stored under `.streamdrop-partials` in the selected output folder. Removing a queue entry does not delete downloaded files or its saved fragments.

## Website support and limitations

Website parsing is provided by the installed version of yt-dlp. Upstream extractor support does not guarantee that every link is accessible from every network or without an account.

Public samples from YouTube, Bilibili, TikTok, X, Weibo, SoundCloud, and AcFun were downloaded during development. These are sample checks, not a complete compatibility guarantee. The following remain outside this version:

- Cookie import, authenticated browser sessions, or an embedded login browser
- Browser extensions and interactive media extraction
- Playlist/batch expansion and live-stream recording
- Automatic yt-dlp updates or an app updater

Douyin samples required fresh cookies. XiaoHongShu samples returned no video formats. Vimeo and Dailymotion samples encountered login requirements, extraction errors, or connection resets. These cases are reported as errors, not silently bypassed. Download only media you have permission to save.

## Testing

Fast tests:

```sh
swift test
```

Tests requiring real media or the executable worker are skipped without the fixture environment. To run the full local suite, including HTTP range resume, MP3 extraction, portrait resizing, and VP9/Opus-to-H.264/AAC conversion:

```sh
python3 -I Verification/test_local.py
```

This generates test patterns locally, starts a loopback-only fixture server on a free port, runs the checks, and removes its generated fixtures afterward. It does not download copyrighted sample media from third-party sites. Test scratch files are kept under the ignored `build/` directory.

`Verification/SiteCheck.swift` can exercise real links using the same download engine. Supply your own cases; account cookies, signed URLs, downloaded media, and machine-specific reports should stay out of the repository.

## Source layout

| File | Responsibility |
| --- | --- |
| `Views.swift` | Main window, link dialog, and settings |
| `DownloadStore.swift` | Queue scheduling, persistence, and task lifecycle |
| `DownloadEngine.swift` | yt-dlp integration and FFmpeg compatibility processing |
| `ProcessRunner.swift` | Streaming process output and owned process-group cancellation |
| `Models.swift` | Download state, media metadata, and URL validation |
| `App.swift` | Application lifecycle and menu commands |

Application sources are in `Sources/StreamDrop`. Build-time icon artwork is generated by `Resources/Icon.swift`.

## License

The original code in this repository is available under the [MIT License](LICENSE). External executables retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
