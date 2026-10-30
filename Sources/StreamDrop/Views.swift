import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let streamAccent = Color(red: 0.48, green: 0.32, blue: 0.89)

private enum QueueFilter: String, CaseIterable, Identifiable {
    case all = "All Downloads", active = "Active", completed = "Completed", failed = "Failed"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .active: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }
    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .active: return item.phase != .completed && item.phase != .failed
        case .completed: return item.phase == .completed
        case .failed: return item.phase == .failed
        }
    }
}

private struct LinkRequest: Identifiable {
    let id = UUID()
    var url: String
}

private struct AppMark: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "arrow.down.to.line.compact")
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(red: 0.66, green: 0.46, blue: 0.98), streamAccent], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.24)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.white.opacity(0.18)))
            .accessibilityHidden(true)
    }
}

struct ContentView: View {
    @EnvironmentObject var store: DownloadStore
    @State private var filter: QueueFilter = .all
    @State private var linkRequest: LinkRequest?
    @State private var isDropTargeted = false

    private var visibleItems: [DownloadItem] { store.items.filter(filter.includes) }
    private var runningCount: Int { store.items.filter { $0.phase.isActive }.count }
    private var resumableCount: Int { store.items.filter { $0.phase == .paused }.count }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if visibleItems.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(visibleItems) { item in
                                DownloadRow(item: item)
                            }
                        }
                        .padding(22)
                    }
                }
                Divider()
                footer
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(streamAccent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .background(streamAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .tint(streamAccent)
        .frame(minWidth: 800, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: pasteLink) {
                    Label("Paste Link", systemImage: "doc.on.clipboard")
                }
                .help("Open a media link from the clipboard")
                Button { linkRequest = LinkRequest(url: "") } label: {
                    Label("Add Link", systemImage: "plus")
                }
                .help("Add a media link")
            }
        }
        .sheet(item: $linkRequest) { request in
            AddLinkView(initialURL: request.url)
                .environmentObject(store)
        }
        .alert("StreamDrop", isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button("OK", role: .cancel) { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StreamDrop.addLink"))) { event in
            linkRequest = LinkRequest(url: event.object as? String ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StreamDrop.pasteLink"))) { _ in
            pasteLink()
        }
        .onDrop(of: [UTType.url.identifier, UTType.utf8PlainText.identifier], isTargeted: $isDropTargeted, perform: receiveDrop)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 11) {
                AppMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("StreamDrop").font(.system(size: 16, weight: .semibold))
                    Text("Your media, offline.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 17)

            VStack(alignment: .leading, spacing: 6) {
                Text("LIBRARY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 6)
                ForEach(QueueFilter.allCases) { candidate in
                    Button { filter = candidate } label: {
                        HStack(spacing: 10) {
                            Image(systemName: candidate.symbol).frame(width: 18)
                            Text(candidate.rawValue).font(.system(size: 12, weight: filter == candidate ? .semibold : .regular))
                            Spacer(minLength: 4)
                            Text("\(store.items.filter(candidate.includes).count)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(filter == candidate ? streamAccent : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .background(filter == candidate ? streamAccent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.rawValue)
                    .accessibilityAddTraits(filter == candidate ? .isSelected : [])
                }
            }
            .padding(.horizontal, 9)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 13) {
                Divider()
                Button(action: store.chooseDestination) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(streamAccent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("SAVE TO").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(.secondary)
                            Text(store.destinationURL.lastPathComponent)
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.destinationURL.path)
                .accessibilityLabel("Choose download folder")
                SettingsLink {
                    Label("Settings", systemImage: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .frame(width: 199)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(filter == .all ? "Downloads" : filter.rawValue)
                    .font(.system(size: 25, weight: .semibold))
                Text(headerSubtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if resumableCount > 0 {
                Button(action: store.resumeAll) {
                    Label("Resume All", systemImage: "play.fill")
                }
                .controlSize(.small)
            }
            if runningCount > 0 || store.items.contains(where: { $0.phase == .queued }) {
                Button(action: store.pauseAll) {
                    Label("Pause All", systemImage: "pause.fill")
                }
                .controlSize(.small)
            }
            if store.items.contains(where: { $0.phase == .completed }) {
                Menu {
                    Button("Clear Completed", action: store.clearCompleted)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 16))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Queue options")
                .accessibilityLabel("Queue options")
            }
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 23)
    }

    private var headerSubtitle: String {
        if store.items.isEmpty { return "A place for the things you want to keep." }
        let count = visibleItems.count
        if runningCount > 0 { return "\(count) \(count == 1 ? "item" : "items") · \(runningCount) downloading" }
        return "\(count) \(count == 1 ? "item" : "items") in your library"
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            if filter == .all {
                AppMark(size: 78)
                    .shadow(color: streamAccent.opacity(0.20), radius: 18, y: 9)
                    .padding(.bottom, 25)
                Text("Good things are worth keeping.")
                    .font(.system(size: 23, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Drop a video link here, or add one to get started.\nChoose your quality. Keep the video or just the audio.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.top, 11)
                HStack(spacing: 10) {
                    Button { linkRequest = LinkRequest(url: "") } label: {
                        Label("Add Link", systemImage: "plus").frame(minWidth: 95)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: pasteLink) {
                        Label("Paste Link", systemImage: "doc.on.clipboard").frame(minWidth: 95)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 26)
                Text("VIDEO  /  AUDIO  /  PLAY IT YOUR WAY")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 33)
            } else {
                Image(systemName: filter.symbol)
                    .font(.system(size: 43, weight: .light))
                    .foregroundStyle(streamAccent.opacity(0.7))
                    .padding(.bottom, 20)
                Text(emptyTitle).font(.system(size: 21, weight: .semibold))
                Text(emptySubtitle).font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .padding(28)
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return "No downloads yet"
        case .active: return "All caught up."
        case .completed: return "Your collection starts here."
        case .failed: return "Everything looks good."
        }
    }

    private var emptySubtitle: String {
        switch filter {
        case .all: return "Add a link to get started."
        case .active: return "New downloads will appear here."
        case .completed: return "Finished videos and audio will appear here."
        case .failed: return "There are no failed downloads."
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(store.engineAvailable ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(store.engineAvailable ? runningCount > 0 ? "\(runningCount) active · \(store.maxConcurrentDownloads) at a time" : "Ready when you are" : "Download tools unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Files stay on your Mac")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .help(store.engineStatus)
    }

    private func pasteLink() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            store.notice = "Copy a media link first, then choose Paste Link."
            return
        }
        presentLink(text)
    }

    private func presentLink(_ text: String) {
        do {
            let url = try validatedMediaURL(text)
            linkRequest = LinkRequest(url: url.absoluteString)
        } catch {
            store.notice = error.localizedDescription
        }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.utf8PlainText.identifier
        provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
            let value: String?
            if let url = item as? URL {
                value = url.absoluteString
            } else if let text = item as? String {
                value = text
            } else if let data = item as? Data {
                value = String(data: data, encoding: .utf8)
            } else {
                value = nil
            }
            Task { @MainActor in
                if let value { presentLink(value) }
                else { store.notice = "Drop an http:// or https:// media link." }
            }
        }
        return true
    }
}

private struct DownloadRow: View {
    @EnvironmentObject var store: DownloadStore
    let item: DownloadItem
    @State private var showsError = false

    private var phaseColor: Color {
        switch item.phase {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        case .queued: return .secondary
        default: return streamAccent
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.mode.symbol)
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(streamAccent)
                .frame(width: 52, height: 57)
                .background(streamAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            .help(item.title)
                        HStack(spacing: 7) {
                            Text(item.host).lineLimit(1).truncationMode(.middle)
                            Text("·")
                            Text(item.formatLabel).fixedSize()
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    actions
                }
                if item.phase == .downloading || item.phase == .paused {
                    ProgressView(value: min(max(item.progress, 0), 1))
                        .tint(item.phase == .paused ? .orange : streamAccent)
                        .accessibilityLabel("Download progress")
                } else if item.phase == .analyzing || item.phase == .processing {
                    ProgressView().progressViewStyle(.linear).tint(streamAccent)
                        .accessibilityLabel(item.phase.label)
                }
                HStack(spacing: 6) {
                    Circle().fill(phaseColor).frame(width: 5, height: 5)
                    Text(item.phase.label).foregroundStyle(phaseColor)
                    if item.phase == .downloading || item.phase == .paused {
                        Text("· \(Int(min(max(item.progress, 0), 1) * 100))%")
                        Text("· \(byteLabel(item.downloadedBytes))\(item.totalBytes.map { " of \(byteLabel($0))" } ?? "")")
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if item.phase == .downloading {
                        if let speed = item.speed, speed > 0 { Text("\(byteLabel(speed))/s").fixedSize() }
                        if let eta = etaLabel(item.eta) { Text("· \(eta)").fixedSize() }
                    }
                    if item.phase == .completed { Text(byteLabel(item.totalBytes ?? item.downloadedBytes)) }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                if item.phase == .failed, let message = item.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Details") { showsError = true }
                            .buttonStyle(.link).font(.system(size: 11))
                            .popover(isPresented: $showsError) {
                                ScrollView { Text(message).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18) }
                                    .frame(width: 440, height: 240)
                            }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        .contextMenu {
            if item.phase == .completed {
                Button("Show in Finder", systemImage: "folder") { store.reveal(item.id) }
            }
            if item.phase == .paused {
                Button("Resume Download", systemImage: "play") { store.resume(item.id) }
            }
            if item.phase == .failed {
                Button("Retry Download", systemImage: "arrow.clockwise") { store.retry(item.id) }
            }
            if [.queued, .analyzing, .downloading].contains(item.phase) {
                Button("Pause Download", systemImage: "pause") { store.pause(item.id) }
            }
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.sourceURL, forType: .string)
            }
            Divider()
            Button("Remove from Queue", systemImage: "trash", role: .destructive) { store.remove(item.id) }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            switch item.phase {
            case .queued, .analyzing, .downloading:
                iconButton("Pause Download", symbol: "pause.fill") { store.pause(item.id) }
            case .paused:
                iconButton("Resume Download", symbol: "play.fill") { store.resume(item.id) }
            case .failed:
                iconButton("Retry Download", symbol: "arrow.clockwise") { store.retry(item.id) }
            case .completed:
                iconButton("Show in Finder", symbol: "folder") { store.reveal(item.id) }
            case .processing:
                EmptyView()
            }
            iconButton("Remove from Queue", symbol: "xmark") { store.remove(item.id) }
        }
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 25, height: 25)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct AddLinkView: View {
    @EnvironmentObject var store: DownloadStore
    @Environment(\.dismiss) private var dismiss
    let initialURL: String
    @State private var url = ""
    @State private var analyzedURL = ""
    @State private var info: MediaInfo?
    @State private var mode: OutputMode = .video
    @State private var quality: VideoQuality = .best
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisID = UUID()
    @FocusState private var urlFocused: Bool

    private var canDownload: Bool {
        info != nil && info?.isLive != true && analyzedURL == url.trimmingCharacters(in: .whitespacesAndNewlines) && !isAnalyzing && store.engineAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 13) {
                AppMark(size: 43)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Add a link").font(.system(size: 22, weight: .semibold))
                    Text("A video for later. Or a soundtrack for anywhere.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("MEDIA LINK").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    TextField("Paste an http:// or https:// link", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($urlFocused)
                        .accessibilityLabel("Media link")
                        .onSubmit { if !isAnalyzing { analyze() } }
                    if isAnalyzing {
                        Button("Stop") { cancelAnalysis() }
                            .controlSize(.large)
                            .frame(width: 86)
                    } else {
                        Button("Analyze", action: analyze)
                            .controlSize(.large)
                            .frame(width: 86)
                            .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.engineAvailable)
                    }
                }
            }

            if !store.engineAvailable {
                messageBox(store.engineStatus, symbol: "exclamationmark.triangle", color: .orange)
            } else if isAnalyzing {
                HStack(spacing: 11) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Finding your media…").font(.system(size: 12, weight: .medium))
                        Text("Reading the title and available formats.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(15)
                .background(streamAccent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            } else if let info {
                mediaPreview(info)
            }

            if let errorMessage {
                messageBox(errorMessage, symbol: "exclamationmark.circle", color: .red)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Save as").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Output format", selection: $mode) {
                        ForEach(OutputMode.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 286)
                    .accessibilityLabel("Output format")
                }
                if mode == .video {
                    HStack {
                        Text("Quality").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("Quality", selection: $quality) {
                            ForEach(VideoQuality.allCases) { option in Text(option.label).tag(option) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel("Video quality")
                    }
                } else {
                    Text("Extract the audio and save it as an MP3 file.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 9) {
                    Image(systemName: "folder").foregroundStyle(streamAccent)
                    Text(store.destinationURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(store.destinationURL.path)
                    Spacer(minLength: 5)
                    Button("Change…", action: store.chooseDestination).controlSize(.small)
                }
            }
            .padding(17)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("One link at a time. Queue as many as you like.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { cancelAnalysis(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: download)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canDownload)
            }
        }
        .padding(28)
        .frame(width: 580)
        .tint(streamAccent)
        .onAppear { url = initialURL; urlFocused = true }
        .onDisappear { cancelAnalysis() }
        .onChange(of: url) { _, _ in
            cancelAnalysis()
            info = nil
            analyzedURL = ""
            errorMessage = nil
        }
    }

    private func mediaPreview(_ media: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30)).foregroundStyle(streamAccent)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 7) {
                    Text(media.title).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                    HStack(spacing: 8) {
                        Text(media.extractor)
                        if let duration = media.durationLabel { Text("·"); Text(duration) }
                        if media.isLive { Text("· Live") }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: media.isLive ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(media.isLive ? .orange : .green)
            }
            if !media.availableHeights.isEmpty {
                Text("Available: \(media.availableHeights.sorted(by: >).map { "\($0)p" }.joined(separator: " · "))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            if media.isLive {
                Text("Live streams are not supported yet. Use a recorded video.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(15)
        .background(streamAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(streamAccent.opacity(0.12)))
    }

    private func messageBox(_ message: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            ScrollView {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
        }
        .padding(12)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func analyze() {
        cancelAnalysis()
        info = nil
        errorMessage = nil
        let requestedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        do { _ = try validatedMediaURL(requestedURL) }
        catch { errorMessage = error.localizedDescription; return }
        let requestID = UUID()
        analysisID = requestID
        isAnalyzing = true
        analysisTask = Task { @MainActor in
            do {
                let media = try await store.inspect(urlString: requestedURL)
                guard !Task.isCancelled, analysisID == requestID else { return }
                info = media
                analyzedURL = requestedURL
                isAnalyzing = false
            } catch {
                guard !Task.isCancelled, analysisID == requestID else { return }
                errorMessage = error.localizedDescription
                isAnalyzing = false
            }
        }
    }

    private func cancelAnalysis() {
        analysisID = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
    }

    private func download() {
        guard canDownload else { return }
        do {
            try store.enqueue(urlString: analyzedURL, info: info, mode: mode, quality: quality)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject var store: DownloadStore

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save files to") {
                    HStack(spacing: 10) {
                        Text(store.destinationURL.lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(store.destinationURL.path)
                        Button("Choose…", action: store.chooseDestination)
                    }
                }
                Stepper(value: $store.maxConcurrentDownloads, in: 1...4) {
                    LabeledContent("Simultaneous downloads", value: "\(store.maxConcurrentDownloads)")
                }
                Text("Paused downloads retain their partial files so they can continue later. Removing a completed item keeps its file on disk.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Download engine") {
                Label(store.engineStatus, systemImage: store.engineAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(store.engineAvailable ? Color.green : Color.orange)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                Text("StreamDrop uses your locally installed yt-dlp and FFmpeg. Keep them up to date to receive support for changes on video sites.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !store.engineAvailable {
                    Text("brew install yt-dlp ffmpeg")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .tint(streamAccent)
        .frame(width: 510, height: 360)
        .navigationTitle("StreamDrop Settings")
    }
}
