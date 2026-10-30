# StreamDrop

使用 SwiftUI、yt-dlp 和 FFmpeg 构建的 macOS 原生媒体下载器。

粘贴链接、解析媒体、选择视频或音频，在本地队列中管理下载。

[English](README.md)

## 功能

- 原生窗口、拖入链接、手动粘贴剪贴板内容
- 下载前解析标题和可用清晰度
- MP4 视频兼容处理：H.264 视频、AAC 音频；另支持提取 MP3
- 最佳画质或 4K、1080p、720p、480p 上限
- 清晰度按画面短边计算，支持竖屏视频
- 并发下载、暂停续传、失败重试、Finder 定位
- 保存队列，重启后将未完成任务恢复为暂停状态
- 无需 StreamDrop 账号，不依赖自建后端

编码兼容时直接复制媒体流；编码不兼容或超出尺寸上限时，在本机转换。转换会占用 CPU，续传能力取决于来源是否支持 Range 请求或分片续传。

## 环境与构建

需要 macOS 14+、带 Swift 6 工具链的 Xcode，以及本机的 yt-dlp、FFmpeg 和 ffprobe。

```sh
brew install yt-dlp ffmpeg
gh repo clone awwcmon/StreamDrop
cd StreamDrop
./build.sh
open build/StreamDrop.app
```

部分网站解析器还需要 Deno 等 JavaScript 运行时，遇到对应错误时可执行 `brew install deno`。

构建脚本只生成当前 Mac 架构的应用，使用 ad-hoc 签名，未经过 Apple 公证。应用不内置或自动安装下载引擎，工具从 `/opt/homebrew/bin`、`/usr/local/bin` 和继承的 `PATH` 中查找。

安装到当前用户的应用目录前，先退出已有的 StreamDrop 实例：

```sh
mkdir -p "$HOME/Applications"
ditto build/StreamDrop.app "$HOME/Applications/StreamDrop.app"
```

## 使用

1. 点击 **Add Link**、**Paste Link**，或将链接拖入窗口。
2. 点击 **Analyze**，确认解析出的媒体信息。
3. 选择 **Video · MP4** 或 **Audio · MP3**，设置清晰度后下载。
4. 在队列中暂停、恢复、重试，或打开文件所在目录。

`⌘N` 打开链接输入框，`⇧⌘V` 手动读取剪贴板链接；设置中可修改下载目录和并发数量。

默认下载目录为 `~/Downloads/StreamDrop`。队列保存在 `~/Library/Application Support/StreamDrop/queue.json`，其中包含来源 URL 和本地路径。分片位于下载目录下的 `.streamdrop-partials`，移除队列项不会删除已下载文件或分片。

## 网站适配边界

网站解析能力来自当前安装的 yt-dlp。适配器存在不代表每个链接都能在当前网络、未登录状态下成功下载。

开发时实测下载过 YouTube、B 站、TikTok、X、微博、SoundCloud、AcFun 的公开样本；这只代表样本结果，不是全站可用性承诺。

当前没有浏览器扩展、Cookie 导入、内嵌登录浏览器、用户引导提取、播放列表批量展开、直播录制或自动更新。抖音样本要求新 Cookie，小红书样本未解析出视频格式，Vimeo、Dailymotion 样本遇到了登录要求、解析失败或连接重置；应用会显示这些错误。请仅保存你有权下载的内容。

## 测试

```sh
swift test
```

未配置测试环境时，需要真实媒体或独立工作进程的测试会被跳过。完整本地验证使用 Python 3：

```sh
python3 -I Verification/test_local.py
```

脚本会生成测试图案和音轨、启动仅监听本机的 HTTP 服务，验证下载、MP3 提取、Range 续传、队列恢复、竖屏尺寸限制和 VP9/Opus 到 H.264/AAC 的转换，结束后清理生成的夹具。测试不依赖第三方网站内容，中间文件放在被 Git 忽略的 `build/` 下。

真实站点可用 `Verification/SiteCheck.swift` 配合自行提供的样本验证；Cookie、签名链接、下载文件和本机报告不应提交到仓库。

## 许可证

本仓库自写代码采用 [MIT](LICENSE)，外部工具保留各自的许可证，详见 [第三方依赖说明](THIRD_PARTY_NOTICES.md)。
