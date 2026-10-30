# Third-party dependencies

StreamDrop invokes locally installed command-line tools. The source repository and the app produced by `build.sh` do not redistribute those tools or their source code.

| Dependency | Role | Licensing notes |
| --- | --- | --- |
| yt-dlp | Website extraction and downloads | The upstream project source uses the Unlicense. Packaged executables and included third-party components may have additional or different license requirements. |
| FFmpeg / ffprobe | Audio/video inspection, merging, conversion, and verification | Licensing depends on the build configuration. FFmpeg can be LGPL or GPL; builds using GPL components such as libx264 are GPL builds. |
| Deno, when installed | JavaScript runtime used by some yt-dlp extractors | Distributed separately; its license and bundled component notices remain applicable. |
| SwiftUI / AppKit / AVFoundation | Native macOS interface and media verification | System frameworks supplied by Apple; not copied into this repository. |

The MIT license in this repository applies to StreamDrop's original code. It does not relicense dependencies or grant rights to media downloaded from third-party websites.

If you change the packaging to embed external executables, review the exact versions and build configurations you ship and satisfy their applicable source, notice, and redistribution requirements. Do not assume the source project's license is the only license governing a downloaded binary.

The app icon is generated from the drawing code in `Resources/Icon.swift`. Interface symbols use Apple's system symbol APIs. No third-party application's executable, framework, or artwork is distributed here.
