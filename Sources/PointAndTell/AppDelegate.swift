#if os(macOS)
import AppKit
import AVFoundation
import PointAndTellCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow!
    private var toolbar: NSPanel!
    private let screenPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "新建录制，边说边指。停止后可转写、校对并导出离线 HTML。")
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let table = NSTableView()
    private let transcriptEditor = NSTextView()
    private let startField = NSTextField(string: "")
    private let endField = NSTextField(string: "")
    private let frameTimeField = NSTextField(string: "0")
    private let framePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview = NSImageView()
    private let cardInfo = NSTextField(labelWithString: "请选择一张卡片")
    private let apiKeyField = NSSecureTextField(string: "")
    private var idleButtons: [NSButton] = []
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var cancelASRButton: NSButton!
    private var store: ProjectStore?
    private var project: ProjectManifest?
    private var screens: [NSScreen] = []
    private let recorder = RecordingEngine()
    private let chunker = AudioChunker()
    private let asr = ASRClient()
    private var asrTask: ASRCancellable?
    private var drawing: DrawingOverlay?
    private var timer: Timer?
    private var selectedDisplay: CGDirectDisplayID = CGMainDisplayID()
    private var pendingScreenshot = false
    private var busy = false
    private var cancelRequested = false
    private var activeChunkID: UUID?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu(); makeWindow(); makeToolbar(); installShortcut()
        recorder.onFailure = { [weak self] error in self?.recordingFailed(error) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.indices.contains(index + 1) { runUISmokeTest(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-smoke-test"), CommandLine.arguments.indices.contains(index + 1) {
            AudioChunkerSmokeTest.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) { result in
                switch result { case .success(let evidence): print(evidence); exit(0); case .failure(let error): fputs("Audio smoke failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        }
    }


    /// Deterministic no-network/no-capture UI fixture for macOS CI. This renders
    /// this app's own view, never takes a screenshot of the user's desktop.
    private func runUISmokeTest(directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let demoStore = ProjectStore(folderURL: directory.appendingPathComponent("fixture.pointtell"))
            var demo = try demoStore.create(title: "Point & Tell · 示例讲解")
            let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.21, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
            context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 80, y: 70, width: 800, height: 370))
            context.setStrokeColor(NSColor.systemRed.cgColor); context.setLineWidth(12); context.strokeEllipse(in: CGRect(x: 580, y: 300, width: 220, height: 105))
            let image = context.makeImage()!; try VisualCapture.save(image, to: demoStore.folderURL.appendingPathComponent("frames/demo.png"))
            let anchor = VisualAnchor(timestamp: 3.2, imageRelativePath: "frames/demo.png", kind: .pen)
            demo.anchors = [anchor]; demo.reviewCards = [ReviewCard(text: "请把右上角这个按钮改大一些，让操作更容易看见。", frameIDs: [anchor.id], startSeconds: 2.1, endSeconds: 7.8), ReviewCard(text: "这句暂时没有可靠时间戳，可以手动选图。")]
            try demoStore.save(demo); store = demoStore; project = demo; report("UI smoke fixture · 没有录屏、麦克风或网络请求"); refresh(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let view = self.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
                do { try data.write(to: directory.appendingPathComponent("window.png")); print("UI_SMOKE_OK \(Int(view.bounds.width))x\(Int(view.bounds.height))"); exit(0) } catch { exit(4) }
            }
        } catch { fputs("UI smoke fixture failed\n", stderr); exit(1) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isRecording || busy {
            let alert = NSAlert(); alert.messageText = "仍有录制或处理正在进行"; alert.informativeText = "请先停止录制或取消转写，再退出。已保存的项目和录音会保留。"; alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { if let key = hotKey { UnregisterEventHotKey(key) }; if let handler = eventHandler { RemoveEventHandler(handler) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !recorder.isRecording && !busy }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy && !recorder.isRecording }

    private func button(_ title: String, _ action: Selector, idleOnly: Bool = false) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        if idleOnly { idleButtons.append(result) }; return result
    }
    private func row(_ views: [NSView]) -> NSStackView { let r = NSStackView(views: views); r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY; return r }
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func makeMenu() {
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let app = NSMenu(); app.addItem(withTitle: "关于 Point & Tell", action: #selector(about), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "退出 Point & Tell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); root.submenu = app
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; NSApp.mainMenu = menu
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1060, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Point & Tell · 指指点点"; window.delegate = self; window.minSize = NSSize(width: 860, height: 650)
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        screens = NSScreen.screens
        for (index, screen) in screens.enumerated() { screenPicker.addItem(withTitle: "屏幕 \(index + 1) · \(screen.localizedName)") }
        fpsPicker.addItems(withTitles: ["5 fps · 省资源", "10 fps"])
        startButton = button("新建并开始录制", #selector(startRecording), idleOnly: true)
        content.addArrangedSubview(row([screenPicker, fpsPicker, startButton, button("打开项目…", #selector(openProject), idleOnly: true), button("显示项目文件", #selector(revealProject))]))
        statusLabel.maximumNumberOfLines = 3; statusLabel.font = .systemFont(ofSize: 12); content.addArrangedSubview(statusLabel)
        apiKeyField.placeholderString = "阿里云 API Key，仅本次内存保存"; apiKeyField.widthAnchor.constraint(equalToConstant: 295).isActive = true
        cancelASRButton = button("取消转写", #selector(cancelASR)); cancelASRButton.isEnabled = false
        content.addArrangedSubview(row([apiKeyField, button("转写 / 重试失败片段", #selector(transcribe), idleOnly: true), cancelASRButton]))
        content.addArrangedSubview(label("只有点击转写才会发送音频给阿里云；截图和视频始终留在本地。请勿录制不愿上传的私密声音。"))
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("card")); column.title = "讲解卡片"; column.width = 250; table.addTableColumn(column)
        table.delegate = self; table.dataSource = self; table.headerView = nil; table.rowHeight = 55
        let tableScroll = NSScrollView(); tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; split.addArrangedSubview(tableScroll)
        let detail = NSStackView(); detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 9; detail.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        detail.addArrangedSubview(cardInfo)
        transcriptEditor.delegate = self; transcriptEditor.isRichText = false;
        transcriptEditor.minSize = NSSize(width: 0, height: 125); transcriptEditor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptEditor.isHorizontallyResizable = false; transcriptEditor.autoresizingMask = .width; transcriptEditor.textContainer?.widthTracksTextView = true; transcriptEditor.font = .systemFont(ofSize: 15); transcriptEditor.isVerticallyResizable = true
        let textScroll = NSScrollView(); textScroll.documentView = transcriptEditor; textScroll.hasVerticalScroller = true
        textScroll.heightAnchor.constraint(equalToConstant: 125).isActive = true; detail.addArrangedSubview(textScroll)
        startField.placeholderString = "起始秒，可空"; endField.placeholderString = "结束秒，可空"
        startField.widthAnchor.constraint(equalToConstant: 110).isActive = true; endField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        detail.addArrangedSubview(row([label("时间"), startField, label("→"), endField, button("保存文字与时间", #selector(saveCard), idleOnly: true)]))
        framePicker.target = self; framePicker.action = #selector(showSelectedFrame); framePicker.widthAnchor.constraint(equalToConstant: 280).isActive = true
        detail.addArrangedSubview(row([framePicker, button("替换配图", #selector(replaceFrame), idleOnly: true), button("添加配图", #selector(appendFrame), idleOnly: true)]))
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        detail.addArrangedSubview(preview)
        frameTimeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        detail.addArrangedSubview(row([label("从录屏取图（秒）"), frameTimeField, button("提取并配图", #selector(extractManualFrame), idleOnly: true), button("清除本卡配图", #selector(clearFrames), idleOnly: true)]))
        split.addArrangedSubview(detail); content.addArrangedSubview(split)
        content.addArrangedSubview(row([button("添加手动卡片", #selector(addCard), idleOnly: true), button("导出 HTML…", #selector(exportHTML), idleOnly: true), button("导出图片 + Markdown…", #selector(exportBundle), idleOnly: true)]))
        window.contentView = NSView(); guard let root = window.contentView else { return }; root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor), split.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -36), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 430), tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 210), tableScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 300), textScroll.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -12), preview.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -12)])
        window.center()
    }
    private func makeToolbar() {
        toolbar = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 420, height: 50), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        toolbar.title = "Point & Tell · 录制中"; toolbar.level = .floating; toolbar.isFloatingPanel = true; toolbar.hidesOnDeactivate = false; toolbar.isReleasedWhenClosed = false
        stopButton = button("停止", #selector(stopRecording))
        let controls = row([timerLabel, button("标记 ⌃⌥M", #selector(mark)), button("画笔", #selector(pen)), stopButton]); controls.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12); toolbar.contentView = controls
    }
    @objc private func about() { let a = NSAlert(); a.messageText = "Point & Tell 0.1.0"; a.informativeText = "适用于 macOS 11+ 的轻量屏幕讲解工具。\n录屏和标注本地保存；转写按需上传音频。\n这是早期版本，真实阿里云接口与旧款 Mac 性能需要设备验证。"; a.runModal() }
    private func setBusy(_ value: Bool, status: String? = nil) { busy = value; transcriptEditor.isEditable = !value; startField.isEnabled = !value; endField.isEnabled = !value; framePicker.isEnabled = !value; frameTimeField.isEnabled = !value; apiKeyField.isEnabled = !value; idleButtons.forEach { $0.isEnabled = !value && !recorder.isRecording }; screenPicker.isEnabled = !value; fpsPicker.isEnabled = !value; if let status = status { statusLabel.stringValue = status } }
    private func persist() throws { if let project = project, let store = store { try store.save(project) } }
    private func fail(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
    private func report(_ text: String) { statusLabel.stringValue = text }
    private func refresh() { table.reloadData(); refreshFramePicker(); if table.selectedRow >= 0 { loadCard() } }
    private var cardIndex: Int? { guard let count = project?.reviewCards.count, table.selectedRow >= 0, table.selectedRow < count else { return nil }; return table.selectedRow }

    @objc private func startRecording() {
        guard !busy, !recorder.isRecording else { return }
        let panel = NSSavePanel(); panel.title = "保存新的本地录制项目"; panel.nameFieldStringValue = "Point-and-Tell-\(Int(Date().timeIntervalSince1970)).pointtell"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw ProjectError.projectAlreadyExists }
            let newStore = ProjectStore(folderURL: folder); project = try newStore.create(title: folder.deletingPathExtension().lastPathComponent); store = newStore
            let index = screenPicker.indexOfSelectedItem
            guard screens.indices.contains(index), let id = screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
            selectedDisplay = id.uint32Value
            let fps = fpsPicker.indexOfSelectedItem == 0 ? 5 : 10
            project?.recording = RecordingInfo(relativePath: "recording.mov", durationSeconds: 0, displayID: selectedDisplay, fps: fps)
            project?.captureState = .recording; try persist(); setBusy(true, status: "正在请求录屏与麦克风权限…")
            recorder.start(displayID: selectedDisplay, fps: fps, outputURL: folder.appendingPathComponent("recording.mov")) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.window.orderOut(nil); self.toolbar.orderFrontRegardless(); self.stopButton.isEnabled = true
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        guard let self = self else { return }; let seconds = Int(self.recorder.elapsedSeconds); self.timerLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                    }
                case .failure(let error): self.recordingFailed(error)
                }
            }
        } catch { fail(error) }
    }
    @objc private func stopRecording() {
        guard recorder.isRecording else { return }
        if drawing != nil { drawing?.done() }
        stopButton.isEnabled = false; timer?.invalidate(); timer = nil
        project?.captureState = .finishing; project?.recording?.durationSeconds = recorder.elapsedSeconds
        do { try persist() } catch { fail(error) }
        recorder.stop { [weak self] result in
            guard let self = self else { return }; self.toolbar.orderOut(nil); self.window.makeKeyAndOrderFront(nil)
            switch result {
            case .success(let movie):
                let duration = AVURLAsset(url: movie).duration.seconds
                if duration.isFinite { self.project?.recording?.durationSeconds = duration }
                self.project?.captureState = .complete
                if self.project?.reviewCards.isEmpty == true {
                    let placeholders = self.project?.anchors.map { ReviewCard(text: "", frameIDs: [$0.id], startSeconds: $0.timestamp, endSeconds: $0.timestamp) } ?? []
                    self.project?.reviewCards = placeholders
                }
                do { try self.persist() } catch { self.fail(error) }
                self.setBusy(false, status: "录制已保存在本地。输入 API Key 后可转写；也可直接添加文字并导出。"); self.refresh()
            case .failure(let error): self.recordingFailed(error)
            }
        }
    }
    private func recordingFailed(_ error: Error) {
        timer?.invalidate(); timer = nil; drawing?.cancel(); drawing = nil; toolbar.orderOut(nil); window.makeKeyAndOrderFront(nil)
        project?.recording?.durationSeconds = recorder.elapsedSeconds
        project?.captureState = .interrupted; try? persist(); setBusy(false, status: "录制中断。已写入的文件保留在项目文件夹，可尝试重新打开。"); fail(error)
    }
    @objc private func mark() { captureAnchor(draw: false) }
    @objc private func pen() { captureAnchor(draw: true) }
    private func captureAnchor(draw: Bool) {
        guard recorder.isRecording, !pendingScreenshot, drawing == nil, let store = store else { return }
        pendingScreenshot = true; toolbar.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }; defer { self.pendingScreenshot = false }
            guard self.recorder.isRecording else { return }
            do {
                let visual = try VisualCapture.screen(displayID: self.selectedDisplay); let timestamp = self.recorder.elapsedSeconds
                if draw, let screen = self.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == self.selectedDisplay }) {
                    self.drawing = DrawingOverlay(image: visual.image, screen: screen) { [weak self] result in
                        guard let self = self else { return }; self.drawing = nil
                        do { if let image = try result.get() { try self.addAnchor(image: image, timestamp: timestamp, kind: .pen, pointer: visual.pointer, endTimestamp: max(timestamp, self.recorder.elapsedSeconds), store: store) } } catch { self.fail(error) }
                        if self.recorder.isRecording { self.toolbar.orderFrontRegardless() }
                    }; self.drawing?.show()
                } else {
                    try self.addAnchor(image: visual.image, timestamp: timestamp, kind: .bookmark, pointer: visual.pointer, store: store); self.toolbar.orderFrontRegardless()
                }
            } catch { self.toolbar.orderFrontRegardless(); self.fail(error) }
        }
    }
    private func addAnchor(image: CGImage, timestamp: Double, kind: AnchorKind, pointer: NormalizedPoint? = nil, endTimestamp: Double? = nil, store: ProjectStore) throws {
        let id = UUID(); let relative = "frames/\(id.uuidString).png"
        try VisualCapture.save(image, to: try store.resolveRelativePath(relative, requireExisting: false), pointer: kind == .bookmark ? pointer : nil)
        project?.anchors.append(VisualAnchor(id: id, timestamp: timestamp, imageRelativePath: relative, kind: kind, pointer: pointer, endTimestamp: endTimestamp)); try persist()
    }

    @objc private func openProject() {
        guard !busy else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.title = "选择 .pointtell 项目文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let chosen = ProjectStore(folderURL: url); project = try chosen.load(); store = chosen
            if let recording = project?.recording, let movie = try? chosen.resolveRelativePath(recording.relativePath, requireExisting: true) {
                let duration = AVURLAsset(url: movie).duration.seconds
                if duration.isFinite && duration > 0 { project?.recording?.durationSeconds = duration; try persist() }
            }
            report("已打开 \(project?.title ?? "项目")。原始录制与失败片段已保留。"); refresh() } catch { fail(error) }
    }
    @objc private func revealProject() { if let url = store?.folderURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }

    @objc private func transcribe() {
        guard !busy, let store = store, let recording = project?.recording else { return }
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { report("请先输入本次转写使用的 API Key。密钥不会保存到项目、日志或导出文件。"); return }
        let alert = NSAlert(); alert.messageText = "将本项目的音频发送给阿里云转写？"; alert.informativeText = "接收方：maas.qianwenaiapi.com\n发送内容：本项目麦克风录音，按约 3 分钟分片。视频和截图不会上传。服务商可能按用量计费。\n该接口尚未通过真实付费请求验证。"; alert.addButton(withTitle: "发送音频并转写"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cancelRequested = false; setBusy(true, status: "准备本地音频分片…"); cancelASRButton.isEnabled = true
        if project?.asrChunks.isEmpty == false { processNextChunk(apiKey: key); return }
        do {
            let movie = try store.resolveRelativePath(recording.relativePath, requireExisting: true)
            chunker.chunk(movieURL: movie, directory: store.folderURL.appendingPathComponent("audio")) { [weak self] result in
                guard let self = self else { return }
                do {
                    let chunks = try result.get()
                    self.project?.asrChunks = chunks.map { ASRChunk(index: $0.index, relativePath: "audio/" + $0.relativePath, startSeconds: $0.startSeconds, durationSeconds: $0.durationSeconds) }
                    try self.persist(); if self.cancelRequested { self.finishASR(cancelled: true) } else { self.processNextChunk(apiKey: key) }
                } catch { self.finishASR(cancelled: false); self.fail(error) }
            }
        } catch { finishASR(cancelled: false); fail(error) }
    }
    private func processNextChunk(apiKey: String) {
        guard !cancelRequested else { finishASR(cancelled: true); return }
        guard let index = project?.asrChunks.firstIndex(where: { $0.state == .pending || $0.state == .failed }), let store = store else { buildReviewFrames(); return }
        guard let chunk = project?.asrChunks[index] else { return }
        activeChunkID = chunk.id; project?.asrChunks[index].state = .transcribing; project?.asrChunks[index].errorMessage = nil
        do {
            try persist(); let wav = try Data(contentsOf: store.resolveRelativePath(chunk.relativePath, requireExisting: true), options: .mappedIfSafe)
            let completed = project?.asrChunks.filter { $0.state == .complete }.count ?? 0
            report("正在转写片段 \(chunk.index + 1) / \(project?.asrChunks.count ?? 0) · 已完成 \(completed)。等待服务商返回，没有估算进度。")
            asrTask = asr.transcribe(wav: wav, apiKey: apiKey) { [weak self] result in
                guard let self = self else { return }; self.asrTask = nil; self.activeChunkID = nil
                guard self.project?.asrChunks.indices.contains(index) == true else { return }
                switch result {
                case .success(let sentences):
                    self.project?.asrChunks[index].sentences = sentences.map { sentence in
                        TranscriptSegment(text: sentence.text, startSeconds: sentence.beginTimeMilliseconds.map { Double($0) / 1000 + chunk.startSeconds }, endSeconds: sentence.endTimeMilliseconds.map { Double($0) / 1000 + chunk.startSeconds })
                    }; self.project?.asrChunks[index].state = .complete
                case .failure(let error):
                    self.project?.asrChunks[index].state = self.cancelRequested ? .pending : .failed
                    self.project?.asrChunks[index].errorMessage = ASRChunk.sanitizedError(error.localizedDescription)
                    try? self.persist(); self.finishASR(cancelled: self.cancelRequested)
                    if !self.cancelRequested { self.fail(error) }; return
                }
                do { try self.persist(); self.processNextChunk(apiKey: apiKey) } catch { self.finishASR(cancelled: false); self.fail(error) }
            }
        } catch { project?.asrChunks[index].state = .failed; project?.asrChunks[index].errorMessage = ASRChunk.sanitizedError(error.localizedDescription); try? persist(); finishASR(cancelled: false); fail(error) }
    }
    @objc private func cancelASR() { cancelRequested = true; asrTask?.cancel(); if asrTask == nil { report("将在当前本地步骤结束后取消；已完成的音频片段保留。") } }
    private func finishASR(cancelled: Bool) {
        let completed = project?.asrChunks.sorted(by: { $0.index < $1.index }).flatMap { $0.sentences } ?? []
        project?.transcripts = completed
        let existing = Set(project?.reviewCards.compactMap { $0.transcriptID } ?? [])
        let partialCards = FrameMatcher.suggestCards(for: completed.filter { !existing.contains($0.id) }, anchors: project?.anchors ?? [])
        project?.reviewCards.append(contentsOf: partialCards)
        project?.captureState = .complete; try? persist(); cancelASRButton.isEnabled = false; setBusy(false, status: cancelled ? "转写已取消。已完成的片段保留，下次会继续未完成片段。" : "转写处理已停止。请检查片段状态；重试只发送未完成或失败的片段。"); refresh()
    }
    private func buildReviewFrames() {
        guard let store = store, let recording = project?.recording else { finishASR(cancelled: false); return }
        let segments = project?.asrChunks.sorted(by: { $0.index < $1.index }).flatMap { $0.sentences } ?? []
        project?.transcripts = segments; project?.captureState = .processing; try? persist()
        report("转写已返回，正在从本地录屏提取配图…")
        let snapshot = project!
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var added: [VisualAnchor] = []; var warning: String?
            do {
                let movie = try store.resolveRelativePath(recording.relativePath, requireExisting: true)
                for segment in segments where segment.isTimed {
                    if DispatchQueue.main.sync(execute: { self?.cancelRequested ?? true }) { break }
                    guard let start = segment.startSeconds, let end = segment.endSeconds else { continue }
                    let count = max(1, Int(min(12, ceil((end - start) / 15))))
                    for offset in 0..<count {
                        let timestamp = start + (end - start) * (Double(offset) + 0.5) / Double(count)
                        if snapshot.anchors.contains(where: { abs($0.timestamp - timestamp) < 1 }) { continue }
                        guard timestamp <= recording.durationSeconds else { warning = "部分句子时间超出录屏范围，请手动校对时间和配图"; continue }
                        let anchor: VisualAnchor = try autoreleasepool {
                            let (image, actual) = try VisualCapture.movieFrame(url: movie, at: timestamp)
                            let id = UUID(); let relative = "frames/\(id.uuidString).png"
                            try VisualCapture.save(image, to: store.resolveRelativePath(relative, requireExisting: false))
                            return VisualAnchor(id: id, timestamp: actual, imageRelativePath: relative)
                        }
                        added.append(anchor)
                    }
                }
            } catch { warning = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self = self else { return }; self.project?.anchors.append(contentsOf: added)
                if self.cancelRequested { self.finishASR(cancelled: true); return }
                // Keep existing user-reviewed cards on retry; only append newly transcribed segments.
                let existing = Set(self.project?.reviewCards.compactMap { $0.transcriptID } ?? [])
                let suggested = FrameMatcher.suggestCards(for: segments.filter { !existing.contains($0.id) }, anchors: self.project?.anchors ?? [])
                self.project?.reviewCards.removeAll { $0.transcriptID == nil && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                self.project?.reviewCards.append(contentsOf: suggested)
                self.project?.captureState = .complete; do { try self.persist() } catch { self.fail(error) }
                self.cancelASRButton.isEnabled = false; self.setBusy(false, status: warning.map { "转写完成，但部分截图失败：\($0)。请手动取图后导出。" } ?? "转写与配图已准备好。请校对文字、时间和图片，再导出。无时间戳的句子需要手动配图。")
                self.refresh(); if !(self.project?.reviewCards.isEmpty ?? true) { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !busy, let index = cardIndex else { return }
        project?.reviewCards[index].text = transcriptEditor.string
        do { try persist() } catch { report("保存文字失败：\(error.localizedDescription)") }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { project?.reviewCards.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let card = project?.reviewCards[row] else { return nil }
        let time = card.startSeconds.map { String(format: "%.1fs", $0) } ?? "时间待校对"
        let text = NSTextField(wrappingLabelWithString: "\(row + 1). \(time) · \(card.frameIDs.count) 张图\n\(card.text.isEmpty ? "（添加讲解文字）" : String(card.text.prefix(45)))")
        text.font = .systemFont(ofSize: 12); return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) { loadCard() }
    private func loadCard() {
        guard let index = cardIndex, let card = project?.reviewCards[index] else { return }
        transcriptEditor.string = card.text; startField.stringValue = card.startSeconds.map { String(format: "%.3f", $0) } ?? ""; endField.stringValue = card.endSeconds.map { String(format: "%.3f", $0) } ?? ""
        cardInfo.stringValue = "卡片 \(index + 1) · \(card.frameIDs.count) 张配图（导出保留所选图片顺序）"
        if let id = card.frameIDs.first, let anchorIndex = project?.anchors.firstIndex(where: { $0.id == id }) { framePicker.selectItem(at: anchorIndex) }
        showSelectedFrame()
    }
    @objc private func saveCard() {
        guard let index = cardIndex else { return }
        let a = startField.stringValue.trimmingCharacters(in: .whitespaces), b = endField.stringValue.trimmingCharacters(in: .whitespaces)
        let start = a.isEmpty ? nil : Double(a), end = b.isEmpty ? nil : Double(b)
        guard (a.isEmpty || start != nil), (b.isEmpty || end != nil), start.map({ $0.isFinite && $0 >= 0 }) ?? true, end.map({ $0.isFinite && $0 >= 0 }) ?? true, !(start != nil && end != nil && end! < start!) else { report("请输入有效的秒数，结束时间不能早于起始时间。"); return }
        project?.reviewCards[index].text = transcriptEditor.string; project?.reviewCards[index].startSeconds = start; project?.reviewCards[index].endSeconds = end
        do { try persist(); table.reloadData(); table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); report("卡片已保存") } catch { fail(error) }
    }
    @objc private func addCard() { guard project != nil else { return }; project?.reviewCards.append(ReviewCard(text: "")); do { try persist(); table.reloadData(); table.selectRowIndexes(IndexSet(integer: (project?.reviewCards.count ?? 1) - 1), byExtendingSelection: false) } catch { fail(error) } }
    private func refreshFramePicker() { framePicker.removeAllItems(); for anchor in project?.anchors ?? [] { framePicker.addItem(withTitle: String(format: "%.2fs · %@", anchor.timestamp, anchor.kind.rawValue)) }; showSelectedFrame() }
    @objc private func showSelectedFrame() {
        let index = framePicker.indexOfSelectedItem
        guard let anchors = project?.anchors, anchors.indices.contains(index), let url = try? store?.resolveRelativePath(anchors[index].imageRelativePath, requireExisting: true) else { preview.image = nil; return }
        preview.image = NSImage(contentsOf: url)
    }
    private func assignFrame(replacing: Bool) {
        guard let index = cardIndex, let anchors = project?.anchors, anchors.indices.contains(framePicker.indexOfSelectedItem) else { return }
        let id = anchors[framePicker.indexOfSelectedItem].id
        if replacing { project?.reviewCards[index].frameIDs = [id] } else if project?.reviewCards[index].frameIDs.contains(id) == false { project?.reviewCards[index].frameIDs.append(id) }
        do { try persist(); loadCard(); table.reloadData() } catch { fail(error) }
    }
    @objc private func replaceFrame() { assignFrame(replacing: true) }
    @objc private func appendFrame() { assignFrame(replacing: false) }
    @objc private func clearFrames() { guard let index = cardIndex else { return }; project?.reviewCards[index].frameIDs = []; do { try persist(); loadCard(); table.reloadData() } catch { fail(error) } }
    @objc private func extractManualFrame() {
        guard let index = cardIndex, let store = store, let recording = project?.recording, let timestamp = Double(frameTimeField.stringValue), timestamp.isFinite, timestamp >= 0, timestamp <= recording.durationSeconds else { report("请选择卡片，并输入录制范围内的秒数。"); return }
        do { let (image, actual) = try VisualCapture.movieFrame(url: store.resolveRelativePath(recording.relativePath, requireExisting: true), at: timestamp); try addAnchor(image: image, timestamp: actual, kind: .frame, store: store); if let id = project?.anchors.last?.id { project?.reviewCards[index].frameIDs.append(id) }; try persist(); refresh(); loadCard() } catch { fail(error) }
    }
    @objc private func exportHTML() { export(bundle: false) }
    @objc private func exportBundle() { export(bundle: true) }
    private func export(bundle: Bool) {
        guard let project = project, let store = store else { return }
        let panel = NSSavePanel(); panel.title = bundle ? "保存图片与 Markdown 文件夹" : "保存独立 HTML"; panel.nameFieldStringValue = bundle ? "Point-and-Tell-export" : "Point-and-Tell.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setBusy(true, status: "正在本地生成导出文件…")
        DispatchQueue.global(qos: .utility).async {
            let result: Result<ExportResult, Error> = Result {
                if bundle { return try ProjectExporter.exportBundle(project: project, store: store, to: url) }
                return try ProjectExporter.exportHTML(project: project, store: store, to: url)
            }
            DispatchQueue.main.async {
                self.setBusy(false)
                switch result {
                case .success(let exported):
                    self.report(exported.warnings.isEmpty ? "导出成功。HTML 可离线打开；给模型使用时，图片 + Markdown 包更稳妥。" : "导出完成，有 \(exported.warnings.count) 条图片警告，请检查导出内容。")
                    NSWorkspace.shared.activateFileViewerSelecting([exported.outputURL])
                case .failure(let error): self.report("导出失败，原始项目已保留。"); self.fail(error)
                }
            }
        }
    }
}

import Carbon
extension AppDelegate {
    private func installShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { app.mark() }; return noErr
        }, 1, &spec, pointer, &eventHandler)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x5054544C, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { report("全局标记快捷键注册失败，可使用浮动工具栏的标记按钮。") }
    }
}
#endif
