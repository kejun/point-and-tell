#if os(macOS)
import AppKit
import AVFoundation
import AVKit
import PointAndTellCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var toolbar: RecordingToolbarPanel!
    private let screenPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphonePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let microphoneLevel = NSLevelIndicator(frame: .zero)
    private let microphoneLabel = NSTextField(labelWithString: "麦克风待机")
    private var microphoneChoices: [RecordingEngine.MicrophoneChoice] = []
    private var playbackWindow: NSWindow?
    private var playbackPlayer: AVPlayer?
    private var silenceUploadApproved = false
    private var captureStateBeforeASR: CaptureState?
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
    private let workspaceTitle = NSTextField(labelWithString: "把想法讲清楚")
    private let workspaceSubtitle = NSTextField(labelWithString: "录下画面和讲解，结束后自动转写成可以分享的图文卡片。")
    private let stepLabel = NSTextField(labelWithString: "01  录制讲解     →     02  转写与整理     →     03  导出分享")
    private var exportHTMLButton: NSButton!
    private var exportBundleButton: NSButton!
    private let cardCount = NSTextField(labelWithString: "讲解卡片")
    private let savedLabel = NSTextField(labelWithString: "文字自动保存")
    private let attachmentLabel = InterfaceStyle.text("尚未配图", size: 11, color: .secondaryLabelColor)
    private let previewEmpty = NSTextField(labelWithString: "暂无画面 · 可选择截图或从录屏取图")
    private let progress = NSProgressIndicator()
    private let reviewContainer = NSView()
    private let emptyContainer = NSView()
    private let emptyTitle = NSTextField(labelWithString: "指向画面，说出想法")
    private let emptyDescription = NSTextField(wrappingLabelWithString: "录制时标记重点、圈画截图。\n结束后，把口述变成清晰的图文反馈。")
    private var reviewContent: NSView!
    private var detailScroll: NSScrollView!
    private var emptyAction: NSButton!
    private var emptySecondary: NSButton!
    private var transcribeButton: NSButton!
    private var editingCardID: UUID?
    private var timingDirty = false
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
    private var workflowReady = false
    private var isTestMode = false
    private var setupController: SetupWindowController?
    private var automaticGate = AutomaticTranscriptionGate()
    private var automaticTranscription = false
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu(); makeWindow(); makeToolbar(); installShortcut()
        recorder.onFailure = { [weak self] error in self?.recordingFailed(error) }
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.indices.contains(index + 1) {
            isTestMode = true; workflowReady = true; updateInterface()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            runUISmokeTest(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-smoke-test"), CommandLine.arguments.indices.contains(index + 1) {
            isTestMode = true
            AudioChunkerSmokeTest.run(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1])) { result in
                switch result { case .success(let evidence): print(evidence); exit(0); case .failure(let error): fputs("Audio smoke failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }; return
        }
        NSApp.activate(ignoringOtherApps: true)
        showSetupPreferences(); setupController?.setLoading()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try APIKeyStore.load() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let key):
                    self.setupController?.restore(key: key)
                    let granted = UserDefaults.standard.bool(forKey: SetupWindowController.consentPreference)
                    if let key = key, UserDefaults.standard.bool(forKey: SetupWindowController.completedPreference),
                       SetupWindowController.readiness(key: key, consent: granted).canEnterWorkspace {
                        self.enterWorkspace(key: key)
                    }
                case .failure(let error): self.setupController?.restore(key: nil, error: error)
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTestMode, workflowReady, !busy, !recorder.isBusy else { return }
        if !currentReadiness.canEnterWorkspace { showSetupPreferences() }
    }

    private var currentReadiness: WorkflowReadiness {
        SetupWindowController.readiness(key: apiKeyField.stringValue,
            consent: UserDefaults.standard.bool(forKey: SetupWindowController.consentPreference))
    }
    @objc private func showSetupPreferences() {
        guard !busy, !recorder.isBusy, commitTiming() else { return }
        workflowReady = false; updateInterface(); window.orderOut(nil)
        if let setup = setupController { setup.showWindow(nil); setup.window?.makeKeyAndOrderFront(nil); return }
        let setup = SetupWindowController(key: apiKeyField.stringValue,
            consentGranted: UserDefaults.standard.bool(forKey: SetupWindowController.consentPreference)) { [weak self] key in
                self?.enterWorkspace(key: key)
            }
        setupController = setup; setup.showWindow(nil); setup.window?.makeKeyAndOrderFront(nil)
    }
    private func enterWorkspace(key: String) {
        guard SetupWindowController.readiness(key: key, consent: true).canEnterWorkspace else {
            setupController?.refreshState(); return
        }
        apiKeyField.stringValue = key
        UserDefaults.standard.set(true, forKey: SetupWindowController.consentPreference)
        UserDefaults.standard.set(true, forKey: SetupWindowController.completedPreference)
        workflowReady = true; refreshScreens(); refreshMicrophones(); updateInterface()
        window.makeKeyAndOrderFront(nil)
        setupController?.close(); setupController = nil
        report("设置已就绪。新建录制，结束后自动转写并提取配图。")
    }
    private func refreshScreens() {
        let oldIndex = screenPicker.indexOfSelectedItem
        let oldID = screens.indices.contains(oldIndex) ? screens[oldIndex].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber : nil
        screens = NSScreen.screens; screenPicker.removeAllItems()
        for (index, screen) in screens.enumerated() {
            screenPicker.addItem(withTitle: "\(index + 1) · \(screen.localizedName)")
            if screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == oldID { screenPicker.selectItem(at: index) }
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
            // Export fixture verifies the same source timing and assets used by the UI.
            let late = VisualAnchor(timestamp: 8.123, imageRelativePath: "frames/demo.png")
            let timed = TranscriptSegment(text: "请查看右上角的按钮。然后确认保存后的状态。", startSeconds: 2.101, endSeconds: 9.999,
                words: [TranscriptWord(text: "请查看右上角的按钮。", startSeconds: 2.101, endSeconds: 3.801),
                        TranscriptWord(text: "然后确认保存后的状态。", startSeconds: 8.003, endSeconds: 9.999)])
            var exportDemo = demo
            exportDemo.anchors.append(late); exportDemo.transcripts = [timed]
            exportDemo.reviewCards = [ReviewCard(transcriptID: timed.id, text: timed.text,
                frameIDs: [anchor.id, late.id], startSeconds: timed.startSeconds, endSeconds: timed.endSeconds)]
            exportDemo.groupReviewCards()
            try ProjectExporter.exportHTML(project: exportDemo, store: demoStore, to: directory.appendingPathComponent("timeline.html"))
            let bundleURL = directory.appendingPathComponent("timeline-bundle")
            if FileManager.default.fileExists(atPath: bundleURL.path) { try FileManager.default.removeItem(at: bundleURL) }
            try ProjectExporter.exportBundle(project: exportDemo, store: demoStore, to: bundleURL)
            try demoStore.save(demo); store = demoStore; project = demo; report("UI smoke fixture · 没有录屏、麦克风或网络请求"); refresh(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                do {
                    func render(_ name: String, width: CGFloat, height: CGFloat, dark: Bool = false) throws {
                        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        self.window.appearance = NSApp.appearance
                        self.window.setContentSize(NSSize(width: width, height: height))
                        self.window.displayIfNeeded()
                        guard let view = self.window.contentView else { throw ProjectError.projectAlreadyExists }
                        view.layoutSubtreeIfNeeded()
                        guard self.preview.bounds.height <= 280, !self.window.contentView!.hasAmbiguousLayout else { exit(5) }
                        for button in [self.exportHTMLButton!, self.exportBundleButton!] {
                            let rect = button.convert(button.bounds, to: view)
                            guard view.bounds.contains(rect), !button.isHidden,
                                  button.bounds.width >= button.intrinsicContentSize.width else { exit(13) }
                        }
                        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
                        try data.write(to: directory.appendingPathComponent(name + ".png"))
                    }
                    guard !self.transcriptEditor.string.isEmpty, self.apiKeyField.stringValue.isEmpty,
                          self.exportHTMLButton.isEnabled && self.exportBundleButton.isEnabled, self.emptyContainer.isHidden,
                          let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                          NSImage(contentsOf: icon) != nil else { exit(2) }
                    try self.verifySetupUI(directory: directory)
                    self.project = exportDemo; self.editingCardID = nil; self.refresh()
                    guard self.table.numberOfRows == 2 else { exit(24) }
                    for (index, card) in exportDemo.reviewCards.enumerated() {
                        self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); self.loadCard()
                        guard self.transcriptEditor.string == card.text, self.preview.image != nil,
                              card.frameIDs.count == 1, card.isTimed else { exit(25) }
                    }
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); self.loadCard()
                    try render("grouped-review", width: 1080, height: 760)
                    try self.verifyFramePicker(store: demoStore)
                    try DrawingOverlay.verifyInteraction(directory: directory, toolbar: self.toolbar)
                    self.project = demo; self.editingCardID = nil; self.refresh()
                    self.window.makeKeyAndOrderFront(nil); self.window.makeFirstResponder(self.table)
                    try render("window", width: 1080, height: 760)
                    try render("review-dark-compact", width: 980, height: 680, dark: true)
                    self.project?.asrChunks = [ASRChunk(relativePath: "audio/legacy.wav", startSeconds: 0,
                        durationSeconds: 10, state: .complete, sentences: [TranscriptSegment(text: "旧的无时间戳结果")])]
                    self.updateInterface()
                    guard self.transcribeButton.title == "重新转写 · 补齐时间戳" else { exit(14) }
                    self.project?.asrChunks = []; self.updateInterface()
                    // A timing draft follows its card across a selection change;
                    // a card without a selected image must not show someone else's.
                    self.startField.stringValue = "3.500"; self.timingDirty = true
                    guard self.commitTiming() else { exit(6) }
                    self.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                    self.loadCard()
                    guard self.preview.image == nil, self.previewEmpty.isHidden == false,
                          self.project?.reviewCards[0].startSeconds == 3.5 else { exit(7) }
                    self.transcriptEditor.string = "自动保存验证"
                    self.textDidChange(Notification(name: NSText.didChangeNotification))
                    guard try demoStore.load().reviewCards[1].text == "自动保存验证" else { exit(8) }
                    self.setBusy(true)
                    guard !self.exportHTMLButton.isEnabled && !self.exportBundleButton.isEnabled, !self.startButton.isEnabled, !self.transcriptEditor.isEditable else { exit(9) }
                    self.setBusy(false)
                    self.project?.reviewCards = []; self.editingCardID = nil; self.refresh()
                    guard self.emptyContainer.isHidden == false, !self.exportHTMLButton.isEnabled && !self.exportBundleButton.isEnabled else { exit(10) }
                    try render("project-empty", width: 1080, height: 760)
                    self.project?.captureState = .interrupted
                    self.project?.recording = RecordingInfo(relativePath: "recording.mov", durationSeconds: 0,
                        displayID: 1, fps: 5)
                    self.updateInterface()
                    guard self.emptyTitle.stringValue == "录制未能开始",
                          self.emptyAction.action == #selector(self.startRecording), self.emptyAction.isEnabled,
                          !self.transcribeButton.isEnabled, !self.emptySecondary.isEnabled else { exit(26) }
                    try render("recording-start-failed", width: 1080, height: 760)
                    let failure = CaptureFailure(stage: .movieStart, underlying: NSError(
                        domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
                            NSLocalizedDescriptionKey: "The operation could not be completed",
                            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12780)
                        ]))
                    let failureAlert = RecordingFailureAlert.make(failure: failure,
                        diagnostic: failure.diagnosticText, savedReport: true)
                    guard failureAlert.messageText == "启动录屏文件写入失败",
                          failureAlert.buttons.last?.title == "复制诊断",
                          let scroll = failureAlert.accessoryView as? NSScrollView,
                          let text = scroll.documentView as? NSTextView,
                          text.isSelectable, !text.isEditable,
                          text.string.contains("NSOSStatusErrorDomain (-12780)") else { exit(27) }
                    failureAlert.layout()
                    if let view = failureAlert.window.contentView,
                       let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(
                            to: directory.appendingPathComponent("recording-error-dialog.png"))
                    }
                    print("CAPTURE_FAILURE_SMOKE_OK · retry state, disabled empty-media actions, nested error codes, copy diagnostics")
                    self.project = nil; self.store = nil; self.refresh()
                    guard self.startButton.isEnabled, !self.transcribeButton.isEnabled else { exit(11) }
                    self.report("新建录制，边说边指。停止后可转写、校对并导出。")
                    try render("welcome", width: 1080, height: 760)
                    self.timerLabel.stringValue = "00:24"
                    self.microphoneLabel.stringValue = "内建麦克风 · −22 dBFS"
                    self.microphoneLevel.doubleValue = -22
                    self.toolbar.showForRecording(on: NSScreen.main)
                    guard self.toolbar.isVisible, self.toolbar.recordingVisible,
                          self.toolbar.level == RecordingToolbarPanel.recordingLevel,
                          !self.toolbar.hidesOnDeactivate, !self.toolbar.canHide,
                          !self.toolbar.canBecomeKey, !self.toolbar.canBecomeMain,
                          self.toolbar.collectionBehavior.contains(.canJoinAllSpaces),
                          self.toolbar.collectionBehavior.contains(.fullScreenAuxiliary) else { exit(21) }
                    self.window.orderFrontRegardless()
                    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
                    guard self.toolbar.isVisible, NSApp.keyWindow !== self.toolbar else { exit(22) }
                    if let palette = self.toolbar.contentView {
                        palette.layoutSubtreeIfNeeded()
                        guard self.stopButton.frame.maxX <= palette.bounds.width else { exit(12) }
                        if let bitmap = palette.bitmapImageRepForCachingDisplay(in: palette.bounds) {
                            palette.cacheDisplay(in: palette.bounds, to: bitmap)
                            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("recording-toolbar.png"))
                        }
                    }
                    self.toolbar.hideAfterRecording()
                    guard !self.toolbar.isVisible, !self.toolbar.recordingVisible else { exit(23) }
                    print("TOOLBAR_SMOKE_OK · persistent nonactivating HUD, all Spaces/full-screen flags, stopped cleanup")
                    print("UI_SMOKE_OK · light/dark, compact layout, empty states, save and busy controls")
                    exit(0)
                } catch { fputs("UI smoke render failed: \(error.localizedDescription)\n", stderr); exit(4) }
            }
        } catch { fputs("UI smoke fixture failed\n", stderr); exit(1) }
    }

    /// Exercises onboarding without asking for real OS permission, writing a
    /// credential, uploading audio, or persisting consent on the CI machine.
    private func verifySetupUI(directory: URL) throws {
        workflowReady = false; updateInterface(); window.orderOut(nil)
        guard !startButton.isEnabled, !actionEnabled(#selector(openProject)), !window.isVisible else { exit(15) }
        var permissionsGranted = false
        var rejectSave = true
        var completions = 0
        let setup = SetupWindowController(key: "", consentGranted: false, permissions: { key, consent in
            WorkflowReadiness(screenPermission: permissionsGranted, microphonePermission: permissionsGranted,
                hasDisplay: true, hasMicrophone: true, hasAPIKey: WorkflowReadiness.validAPIKey(key), automaticUploadConsent: consent)
        }, saveKey: { _, callback in
            callback(rejectSave ? .failure(APIKeyStore.StoreError(status: -25308)) : .success(()))
        }, completion: { _ in completions += 1 })
        setup.showWindow(nil); setup.window?.makeKeyAndOrderFront(nil)
        func render(_ name: String) throws {
            guard let view = setup.window?.contentView else { exit(16) }
            view.layoutSubtreeIfNeeded()
            let bounds = setup.continueButton.convert(setup.continueButton.bounds, to: view)
            guard view.bounds.contains(bounds), !view.hasAmbiguousLayout,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(17) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        guard !setup.continueButton.isEnabled else { exit(18) }
        try render("setup-required")
        permissionsGranted = true; setup.keyField.stringValue = "offline-setup-fixture-key"; setup.refreshState()
        guard !setup.continueButton.isEnabled else { exit(19) } // Consent still absent.
        setup.consent.state = .on; setup.refreshState()
        guard setup.continueButton.isEnabled else { exit(20) }
        try render("setup-ready")
        setup.finishSetup()
        guard completions == 0, setup.continueButton.isEnabled else { exit(21) } // Keychain failure keeps gate closed.
        rejectSave = false; setup.finishSetup(); setup.finishSetup()
        guard completions == 1 else { exit(22) }
        workflowReady = true; updateInterface(); window.makeKeyAndOrderFront(nil); setup.close()
        print("SETUP_SMOKE_OK · permissions/key/consent gate, keychain failure, one completion, no real credentials or permissions")
    }

    private func verifyFramePicker(store: ProjectStore) throws {
        guard let anchors = project?.anchors, anchors.count >= 2 else { exit(26) }
        project?.reviewCards[0].frameIDs = []; refresh()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); loadCard()
        framePicker.selectItem(at: 0)
        guard project?.reviewCards[0].frameIDs.isEmpty == true else { exit(27) }
        // Only the user action persists; loading/selecting a card does not.
        framePicker.sendAction(framePicker.action, to: framePicker.target)
        guard try store.load().reviewCards[0].frameIDs == [anchors[0].id], preview.image != nil else { exit(28) }
        framePicker.selectItem(at: 1); framePicker.sendAction(framePicker.action, to: framePicker.target)
        guard try store.load().reviewCards[0].frameIDs == [anchors[1].id] else { exit(29) }
        let first = project!.reviewCards[0]
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); loadCard()
        framePicker.selectItem(at: 0); framePicker.sendAction(framePicker.action, to: framePicker.target)
        guard try store.load().reviewCards[1].frameIDs == [anchors[0].id], project?.reviewCards[0] == first else { exit(30) }
        let snapshot = project!.reviewCards
        refresh(); setBusy(true)
        framePicker.selectItem(at: 1); framePicker.sendAction(framePicker.action, to: framePicker.target)
        guard project?.reviewCards == snapshot, !framePicker.isEnabled else { exit(31) }
        setBusy(false)
        print("FRAME_PICKER_SMOKE_OK · select adds, next selection replaces, saved immediately, card switching/refresh/busy state never assigns")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isRecording || busy {
            let alert = NSAlert(); alert.messageText = "仍有录制或处理正在进行"; alert.informativeText = "请先停止录制或取消转写，再退出。已保存的项目和录音会保留。"; alert.runModal()
            return .terminateCancel
        }
        guard commitTiming() else { return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { if let key = hotKey { UnregisterEventHotKey(key) }; if let handler = eventHandler { RemoveEventHandler(handler) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !recorder.isRecording && !busy }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === playbackWindow { closePlayback(); return true }
        return !busy && !recorder.isBusy && commitTiming()
    }

    private func button(_ title: String, _ action: Selector, idleOnly: Bool = false) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded; result.font = .systemFont(ofSize: 12)
        if idleOnly { idleButtons.append(result) }; return result
    }
    private func row(_ views: [NSView]) -> NSStackView { let r = NSStackView(views: views); r.orientation = .horizontal; r.distribution = .fill; r.spacing = 8; r.alignment = .centerY; return r }
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func makeMenu() {
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let app = NSMenu(); app.addItem(withTitle: "关于 Point & Tell", action: #selector(about), keyEquivalent: "")
        app.addItem(withTitle: "权限与转写设置…", action: #selector(showSetupPreferences), keyEquivalent: ",").target = self
        app.addItem(.separator()); app.addItem(withTitle: "退出 Point & Tell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); root.submenu = app
        let fileItem = NSMenuItem(); menu.addItem(fileItem); let file = NSMenu(title: "文件")
        for (title, action, key) in [("新建录制…", #selector(startRecording), "n"), ("打开项目…", #selector(openProject), "o"), ("保存卡片", #selector(saveCard), "s"), ("导出 HTML…", #selector(exportHTML), "e")] {
            let item = file.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        fileItem.submenu = file
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; NSApp.mainMenu = menu
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1080, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Point & Tell · 指指点点"; window.delegate = self
        window.contentMinSize = NSSize(width: 980, height: 680)
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("PointAndTell.Workspace.v2")
        let root = WindowBackgroundView(); window.contentView = root
        let sidebar = SurfaceView(); sidebar.radius = 0; sidebar.fill = .controlBackgroundColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        let main = NSView(); main.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 226),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor), main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        makeSidebar(in: sidebar)
        makeWorkspace(in: main)
        updateInterface()
        window.initialFirstResponder = startButton
        window.center()
    }

    private func makeSidebar(in parent: NSView) {
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            icon.image = image; NSApp.applicationIconImage = image
        }
        icon.widthAnchor.constraint(equalToConstant: 42).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let brand = row([icon, InterfaceStyle.column([
            InterfaceStyle.text("Point & Tell", size: 16, weight: .bold),
            InterfaceStyle.text("指指点点", size: 11, color: .secondaryLabelColor)
        ], spacing: 3)])
        startButton = button("新建录制", #selector(startRecording), idleOnly: true)
        decorate(startButton, symbol: "record.circle", primary: true)
        startButton.toolTip = "创建本地项目并开始录屏与麦克风录音（⌘N）"
        let open = button("打开项目…", #selector(openProject), idleOnly: true); decorate(open, symbol: "folder")
        screens = NSScreen.screens
        for (index, screen) in screens.enumerated() { screenPicker.addItem(withTitle: "\(index + 1) · \(screen.localizedName)") }
        screenPicker.setAccessibilityLabel("录制屏幕")
        fpsPicker.addItems(withTitles: ["5 fps · 更省资源", "10 fps · 更流畅"]); fpsPicker.setAccessibilityLabel("录制帧率")
        microphonePicker.setAccessibilityLabel("录音麦克风"); refreshMicrophones()
        let refresh = button("刷新", #selector(refreshMicrophones), idleOnly: true); refresh.controlSize = .small
        let micHeading = row([caption("麦克风"), InterfaceStyle.spacer(), refresh])
        let settings = InterfaceStyle.column([
            sectionHeading("录制设置", symbol: "slider.horizontal.3"), caption("屏幕"), screenPicker,
            caption("帧率"), fpsPicker, micHeading, microphonePicker
        ], spacing: 7)
        let playback = button("试听录屏", #selector(playRecording), idleOnly: true); decorate(playback, symbol: "play.circle")
        apiKeyField.placeholderString = "输入阿里云 API Key"
        apiKeyField.font = .systemFont(ofSize: 12); apiKeyField.setAccessibilityLabel("阿里云转写 API Key")
        apiKeyField.toolTip = "密钥保存在本机钥匙串，不写入项目、日志或导出文件。"
        transcribeButton = button("开始转写", #selector(transcribe), idleOnly: true); decorate(transcribeButton, symbol: "waveform")
        cancelASRButton = button("取消转写", #selector(cancelASR)); cancelASRButton.isEnabled = false
        cancelASRButton.isHidden = true
        let settingsButton = button("权限与转写设置…", #selector(showSetupPreferences), idleOnly: true)
        settingsButton.controlSize = .small
        let transcription = InterfaceStyle.column([
            sectionHeading("语音转文字", symbol: "waveform"),
            caption("Qwen Audio 3.0 · 句 / 词时间戳"), caption("结束录制后自动转写"), transcribeButton, cancelASRButton,
            settingsButton, caption("API Key 由本机钥匙串保管。仅上传音频，视频和截图保留在本地。")
        ], spacing: 8)
        let reveal = button("在 Finder 中显示", #selector(revealProject), idleOnly: true)
        reveal.controlSize = .small; decorate(reveal, symbol: "folder")
        let stack = InterfaceStyle.column([brand, startButton, open, InterfaceStyle.separator(), settings,
            playback, InterfaceStyle.separator(), transcription, InterfaceStyle.separator(), reveal], spacing: 12)
        let scroll = scrolling(stack, inset: 16)
        InterfaceStyle.pin(scroll, to: parent)
    }

    private func makeWorkspace(in parent: NSView) {
        workspaceTitle.font = .systemFont(ofSize: 23, weight: .bold)
        workspaceTitle.lineBreakMode = .byTruncatingTail; workspaceTitle.maximumNumberOfLines = 1
        workspaceTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceSubtitle.font = .systemFont(ofSize: 12); workspaceSubtitle.textColor = .secondaryLabelColor
        exportHTMLButton = button("导出独立 HTML…", #selector(exportHTML), idleOnly: false)
        exportBundleButton = button("导出图片 + Markdown…", #selector(exportBundle), idleOnly: false)
        decorate(exportHTMLButton, symbol: "doc.richtext", primary: true)
        decorate(exportBundleButton, symbol: "folder")
        exportHTMLButton.toolTip = "导出可离线打开的独立网页（⌘E），按时间戳对齐语音和截图。"
        exportBundleButton.toolTip = "导出包含图片、Markdown、独立 HTML 和图文时间信息的文件夹。"
        exportHTMLButton.setAccessibilityLabel("导出独立 HTML 网页")
        exportBundleButton.setAccessibilityLabel("导出图片和 Markdown 文件夹")
        let titleGroup = InterfaceStyle.column([workspaceTitle, workspaceSubtitle], spacing: 5)
        let header = titleGroup
        let exports = row([exportHTMLButton!, exportBundleButton!, InterfaceStyle.spacer()])
        stepLabel.font = .systemFont(ofSize: 11, weight: .medium); stepLabel.textColor = InterfaceStyle.accent

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("card")); column.title = "讲解卡片"
        table.addTableColumn(column); table.delegate = self; table.dataSource = self
        table.headerView = nil; table.rowHeight = 92; table.intercellSpacing = NSSize(width: 0, height: 6)
        table.style = .sourceList; table.backgroundColor = .clear; table.allowsEmptySelection = false
        table.setAccessibilityLabel("讲解卡片列表")
        let tableScroll = NSScrollView(); tableScroll.documentView = table; tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        let add = button("添加", #selector(addCard), idleOnly: true); add.controlSize = .small; decorate(add, symbol: "plus")
        cardCount.font = .systemFont(ofSize: 12, weight: .semibold)
        let listHeader = row([cardCount, InterfaceStyle.spacer(), add])
        let list = InterfaceStyle.column([listHeader, tableScroll], spacing: 12)
        list.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let listSurface = SurfaceView(); InterfaceStyle.pin(list, to: listSurface, inset: 12)
        listSurface.widthAnchor.constraint(equalToConstant: 214).isActive = true

        let details = makeCardDetail()
        detailScroll = scrolling(details, inset: 16)
        let detailSurface = SurfaceView(); InterfaceStyle.pin(detailScroll, to: detailSurface)
        let review = row([listSurface, detailSurface]); review.alignment = .top; review.spacing = 16
        NSLayoutConstraint.activate([listSurface.heightAnchor.constraint(equalTo: review.heightAnchor), detailSurface.heightAnchor.constraint(equalTo: review.heightAnchor)])
        review.translatesAutoresizingMaskIntoConstraints = false; reviewContainer.addSubview(review)
        NSLayoutConstraint.activate([review.leadingAnchor.constraint(equalTo: reviewContainer.leadingAnchor), review.trailingAnchor.constraint(equalTo: reviewContainer.trailingAnchor), review.topAnchor.constraint(equalTo: reviewContainer.topAnchor), review.bottomAnchor.constraint(equalTo: reviewContainer.bottomAnchor)])
        reviewContent = review
        reviewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        makeEmptyState(in: reviewContainer)

        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2; statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true; progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let status = row([progress, statusLabel]); status.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let stack = InterfaceStyle.column([header, exports, stepLabel, reviewContainer, InterfaceStyle.separator(), status], spacing: 16)
        InterfaceStyle.pin(stack, to: parent, inset: 22)
    }

    private func makeCardDetail() -> NSStackView {
        cardInfo.font = .systemFont(ofSize: 16, weight: .semibold)
        savedLabel.font = .systemFont(ofSize: 10); savedLabel.textColor = .secondaryLabelColor
        let title = row([cardInfo, InterfaceStyle.spacer(), savedLabel])
        transcriptEditor.delegate = self; transcriptEditor.isRichText = false; transcriptEditor.allowsUndo = true
        transcriptEditor.minSize = NSSize(width: 0, height: 92)
        transcriptEditor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptEditor.isHorizontallyResizable = false; transcriptEditor.autoresizingMask = .width
        transcriptEditor.textContainer?.widthTracksTextView = true
        transcriptEditor.font = .systemFont(ofSize: 14); transcriptEditor.textColor = .labelColor
        transcriptEditor.backgroundColor = .textBackgroundColor; transcriptEditor.isVerticallyResizable = true
        transcriptEditor.textContainerInset = NSSize(width: 10, height: 10)
        transcriptEditor.setAccessibilityLabel("讲解文字，自动保存")
        let textScroll = NSScrollView(); textScroll.documentView = transcriptEditor; textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder; textScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        startField.placeholderString = "起始"; endField.placeholderString = "结束"
        startField.setAccessibilityLabel("起始时间，秒"); endField.setAccessibilityLabel("结束时间，秒")
        startField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        endField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        startField.delegate = self; endField.delegate = self
        let save = button("保存时间", #selector(saveCard), idleOnly: true); save.controlSize = .small
        let timing = row([caption("秒"), startField, caption("—"), endField, InterfaceStyle.spacer(), save])
        framePicker.target = self; framePicker.action = #selector(selectFrame)
        framePicker.setAccessibilityLabel("卡片截图，选择后自动保存，再次选择即替换")
        framePicker.toolTip = "选择截图即保存；再次选择会替换当前卡片的配图。"
        framePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        framePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.setAccessibilityLabel("截图预览")
        let previewSurface = SurfaceView(); previewSurface.fill = .windowBackgroundColor; previewSurface.radius = 8
        InterfaceStyle.pin(preview, to: previewSurface, inset: 8)
        previewSurface.heightAnchor.constraint(equalToConstant: 160).isActive = true
        previewEmpty.font = .systemFont(ofSize: 12); previewEmpty.textColor = .secondaryLabelColor
        previewEmpty.alignment = .center; previewEmpty.translatesAutoresizingMaskIntoConstraints = false; previewSurface.addSubview(previewEmpty)
        NSLayoutConstraint.activate([previewEmpty.centerXAnchor.constraint(equalTo: previewSurface.centerXAnchor), previewEmpty.centerYAnchor.constraint(equalTo: previewSurface.centerYAnchor)])
        let clear = button("移除配图", #selector(clearFrames), idleOnly: true)
        clear.controlSize = .small
        let images = row([framePicker])
        frameTimeField.widthAnchor.constraint(equalToConstant: 74).isActive = true; frameTimeField.setAccessibilityLabel("从录屏取图的时间，秒")
        let extract = button("提取", #selector(extractManualFrame), idleOnly: true); extract.controlSize = .small
        let extraction = row([caption("取图 / 秒"), frameTimeField, extract, InterfaceStyle.spacer(), clear])
        return InterfaceStyle.column([title, textScroll, timing, InterfaceStyle.separator(),
            sectionHeading("画面与标注", symbol: "photo"), previewSurface, attachmentLabel, images, extraction], spacing: 9)
    }

    private func makeEmptyState(in parent: NSView) {
        emptyTitle.font = .systemFont(ofSize: 24, weight: .bold); emptyTitle.alignment = .center
        emptyDescription.font = .systemFont(ofSize: 13); emptyDescription.textColor = .secondaryLabelColor
        emptyDescription.alignment = .center
        emptyAction = button("开始第一次录制", #selector(startRecording), idleOnly: true)
        decorate(emptyAction, symbol: "record.circle", primary: true)
        emptySecondary = button("打开已有项目…", #selector(openProject), idleOnly: true)
        let hero = InterfaceStyle.symbol("rectangle.on.rectangle", size: 52)
        let leadingSpace = InterfaceStyle.spacer(), trailingSpace = InterfaceStyle.spacer()
        let symbolRow = row([leadingSpace, hero, trailingSpace])
        leadingSpace.widthAnchor.constraint(equalTo: trailingSpace.widthAnchor).isActive = true
        let stack = InterfaceStyle.column([symbolRow, emptyTitle, emptyDescription, emptyAction, emptySecondary], spacing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false; emptyContainer.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor), stack.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor), stack.widthAnchor.constraint(equalToConstant: 350)])
        InterfaceStyle.pin(emptyContainer, to: parent)
    }

    private func scrolling(_ content: NSView, inset: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autohidesScrollers = true; scroll.horizontalScrollElasticity = .none
        let document = FlippedContentView(); scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        InterfaceStyle.pin(content, to: document, inset: inset)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)])
        return scroll
    }
    private func caption(_ text: String) -> NSTextField { InterfaceStyle.text(text, size: 11, color: .secondaryLabelColor) }
    private func sectionHeading(_ text: String, symbol: String) -> NSStackView {
        row([InterfaceStyle.symbol(symbol, size: 14), InterfaceStyle.text(text, size: 12, weight: .semibold)])
    }
    private func decorate(_ button: NSButton, symbol: String, primary: Bool = false) {
        button.bezelStyle = .rounded; button.imagePosition = .imageLeading
        if button.controlSize != .small { button.controlSize = .large }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.font = .systemFont(ofSize: primary ? 13 : 12, weight: primary ? .semibold : .regular)
        if primary { button.bezelColor = NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.31, alpha: 1); button.contentTintColor = .white }
        button.setAccessibilityLabel(button.title)
    }
    private func makeToolbar() {
        toolbar = RecordingToolbarPanel()
        stopButton = button("结束录制", #selector(stopRecording)); decorate(stopButton, symbol: "stop.fill")
        stopButton.contentTintColor = .systemRed
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        timerLabel.widthAnchor.constraint(equalToConstant: 68).isActive = true
        microphoneLabel.font = .systemFont(ofSize: 11)
        microphoneLevel.levelIndicatorStyle = .continuousCapacity
        microphoneLevel.minValue = -60; microphoneLevel.maxValue = 0; microphoneLevel.doubleValue = -60
        microphoneLevel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        microphoneLevel.toolTip = "麦克风平均电平，−60 至 0 dBFS；有电平不等于一定是人声"
        microphoneLabel.widthAnchor.constraint(equalToConstant: 215).isActive = true
        microphoneLabel.lineBreakMode = .byTruncatingMiddle
        let controls = row([InterfaceStyle.symbol("record.circle.fill", size: 14), timerLabel, microphoneLabel, microphoneLevel, button("标记 ⌃⌥M", #selector(mark)), button("画笔", #selector(pen)), stopButton]); controls.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let background = WindowBackgroundView(); toolbar.contentView = background
        InterfaceStyle.pin(controls, to: background, inset: 0)
    }
    @objc private func about() { let a = NSAlert(); a.messageText = "Point & Tell " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""); a.informativeText = "适用于 macOS 11+ 的轻量屏幕讲解工具。\n录屏和标注本地保存；完成首次设置后，录制结束会自动上传音频转写。\n语音服务使用 qwen-audio-3.0-asr-flash。"; a.runModal() }
    private func setBusy(_ value: Bool, status: String? = nil) {
        busy = value
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        if let status = status { report(status) }
        updateInterface()
    }
    private func persist() throws { if let project = project, let store = store { try store.save(project) } }
    private func fail(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
    private func report(_ text: String) { statusLabel.stringValue = text; statusLabel.toolTip = text }
    private func actionEnabled(_ action: Selector?) -> Bool {
        guard !busy, !recorder.isBusy else { return false }
        if action == #selector(showSetupPreferences) { return true }
        guard workflowReady else { return false }
        switch action {
        case #selector(startRecording), #selector(openProject), #selector(refreshMicrophones): return true
        case #selector(revealProject), #selector(addCard): return project != nil
        case #selector(playRecording), #selector(transcribe): return project?.recording != nil && !recordingNeverStarted
        case #selector(exportHTML), #selector(exportBundle): return !(project?.reviewCards.isEmpty ?? true) || !(project?.transcripts.isEmpty ?? true)
        case #selector(saveCard): return cardIndex != nil
        case #selector(clearFrames): return cardIndex.map { !(project?.reviewCards[$0].frameIDs.isEmpty ?? true) } ?? false
        case #selector(selectFrame): return cardIndex != nil && framePicker.selectedItem != nil
        case #selector(extractManualFrame): return cardIndex != nil && project?.recording != nil
        default: return true
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { actionEnabled(menuItem.action) }
    private func updateInterface() {
        guard reviewContent != nil else { return }
        idleButtons.forEach { $0.isEnabled = actionEnabled($0.action) }
        let editable = !busy && !recorder.isBusy && cardIndex != nil
        transcriptEditor.isEditable = editable; startField.isEnabled = editable; endField.isEnabled = editable
        framePicker.isEnabled = editable && !(project?.anchors.isEmpty ?? true)
        frameTimeField.isEnabled = editable && project?.recording != nil
        apiKeyField.isEnabled = !busy; screenPicker.isEnabled = !busy; fpsPicker.isEnabled = !busy; microphonePicker.isEnabled = !busy
        table.isEnabled = !busy
        exportHTMLButton.isEnabled = actionEnabled(#selector(exportHTML))
        exportBundleButton.isEnabled = actionEnabled(#selector(exportBundle))
        cancelASRButton.isHidden = !cancelASRButton.isEnabled
        if project?.asrChunks.contains(where: { $0.needsTimestampRetry }) == true {
            transcribeButton.title = "重新转写 · 补齐时间戳"
        } else {
            transcribeButton.title = (project?.asrChunks.contains { $0.state == .failed || $0.state == .pending } ?? false) ? "继续 / 重试转写" : "开始转写"
        }
        transcribeButton.toolTip = "qwen-audio-3.0-asr-flash · 校验完整句/词时间戳后才标记完成。"
        let count = project?.reviewCards.count ?? 0
        cardCount.stringValue = "卡片 · \(count)"
        workspaceTitle.stringValue = project?.title ?? "把想法讲清楚"
        workspaceTitle.toolTip = project?.title
        workspaceSubtitle.stringValue = project.map { "\(count) 张讲解卡片 · \($0.anchors.count) 张截图 · 本地项目" } ?? "录下画面和讲解，结束后自动转写成可以分享的图文卡片。"
        reviewContent.isHidden = count == 0; emptyContainer.isHidden = count > 0
        emptyTitle.stringValue = project == nil ? "指向画面，说出想法" : (recordingNeverStarted ? "录制未能开始" : "录制已就位，开始整理")
        emptyDescription.stringValue = project == nil ? "录制时标记重点、圈画截图。\n结束后，把口述变成清晰的图文反馈。" : (recordingNeverStarted ? "请根据错误提示检查后，重新新建录制。\n本次项目与已写入的文件保留，未启动自动转写。" : "录制结束后自动转写。若未完成，可从左侧继续或重试。\n原始录屏始终保留，也可手动整理。")
        emptyAction.title = project == nil ? "开始第一次录制" : (recordingNeverStarted ? "重新新建录制" : "添加第一张卡片")
        emptyAction.action = project == nil || recordingNeverStarted ? #selector(startRecording) : #selector(addCard)
        emptyAction.setAccessibilityLabel(emptyAction.title)
        emptyAction.isEnabled = actionEnabled(emptyAction.action)
        emptySecondary.title = project == nil ? "打开已有项目…" : "试听录屏"
        emptySecondary.action = project == nil ? #selector(openProject) : #selector(playRecording)
        emptySecondary.isEnabled = actionEnabled(emptySecondary.action)
    }
    private func refresh() {
        let selectedID = editingCardID
        table.reloadData(); refreshFramePicker()
        let cards = project?.reviewCards ?? []
        if !cards.isEmpty {
            let index = cards.firstIndex { $0.id == selectedID } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        loadCard(); updateInterface()
    }
    private var cardIndex: Int? { guard let count = project?.reviewCards.count, table.selectedRow >= 0, table.selectedRow < count else { return nil }; return table.selectedRow }
    private var recordingNeverStarted: Bool {
        project?.captureState == .interrupted && (project?.recording?.durationSeconds ?? 0) <= 0
    }

    @objc private func startRecording() {
        guard !busy, !recorder.isBusy else { return }
        guard isTestMode || (workflowReady && currentReadiness.canEnterWorkspace) else { showSetupPreferences(); return }
        refreshScreens(); refreshMicrophones()
        guard commitTiming() else { return }
        closePlayback()
        let panel = NSSavePanel(); panel.title = "保存新的本地录制项目"; panel.nameFieldStringValue = "Point-and-Tell-\(Int(Date().timeIntervalSince1970)).pointtell"; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw ProjectError.projectAlreadyExists }
            let newStore = ProjectStore(folderURL: folder); project = try newStore.create(title: folder.deletingPathExtension().lastPathComponent); store = newStore
            let index = screenPicker.indexOfSelectedItem
            guard screens.indices.contains(index), let id = screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
            editingCardID = nil; timingDirty = false; refresh()
            selectedDisplay = id.uint32Value
            let fps = fpsPicker.indexOfSelectedItem == 0 ? 5 : 10
            project?.recording = RecordingInfo(relativePath: "recording.mov", durationSeconds: 0, displayID: selectedDisplay, fps: fps)
            project?.captureState = .recording; try persist(); setBusy(true, status: "正在启动屏幕与麦克风录制…")
            recorder.start(displayID: selectedDisplay, fps: fps, microphoneID: microphonePicker.selectedItem?.representedObject as? String, outputURL: folder.appendingPathComponent("recording.mov")) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    if let id = self.project?.id { self.automaticGate.arm(projectID: id) }
                    self.window.orderOut(nil)
                    let screen = self.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == self.selectedDisplay }
                    self.toolbar.showForRecording(on: screen); self.stopButton.isEnabled = true
                    self.updateMicrophoneMeter()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                        guard let self = self else { return }; let seconds = Int(self.recorder.elapsedSeconds); self.timerLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60); self.updateMicrophoneMeter()
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
            guard let self = self else { return }; self.toolbar.hideAfterRecording(); self.window.makeKeyAndOrderFront(nil)
            switch result {
            case .success(let movie):
                self.setBusy(true, status: "录屏已保存，正在本地检查音轨和实际解码电平…")
                DispatchQueue.global(qos: .utility).async {
                    let inspection = Result { try AudioInspector.inspect(movieURL: movie) }
                    let duration = AVURLAsset(url: movie).duration.seconds
                    DispatchQueue.main.async {
                        if duration.isFinite { self.project?.recording?.durationSeconds = duration }
                        switch inspection {
                        case .success(let report):
                            self.project?.captureState = .complete
                            if self.project?.reviewCards.isEmpty == true {
                                let placeholders = self.project?.anchors.map { ReviewCard(text: "", frameIDs: [$0.id], startSeconds: $0.timestamp, endSeconds: $0.timestamp) } ?? []
                                self.project?.reviewCards = placeholders
                            }
                            do { try self.persist() } catch {
                                self.automaticGate.cancel(); self.setBusy(false, status: "保存项目失败，自动转写未启动；录音已保留。")
                                self.fail(error); return
                            }
                            let ready = self.workflowReady && self.currentReadiness.canEnterWorkspace
                            let message = report.suspectedSilence
                                ? "录音检查：电平很低，可能是静音。请先本地试听，再检查所选麦克风和系统输入音量。"
                                : (ready ? "录音检查通过，准备自动转写。" : "权限、设备或转写设置发生变化，自动转写未启动。请完成设置后手动继续转写。")
                            self.setBusy(false, status: message + " " + report.safeSummary); self.refresh()
                            if let id = self.project?.id,
                               self.automaticGate.consume(projectID: id, usableAudio: true,
                                   needsAudioReview: report.suspectedSilence, ready: ready) {
                                self.beginTranscription(automatic: true, sourceInspection: report)
                            }
                        case .failure(let error):
                            self.automaticGate.cancel()
                            self.project?.captureState = .interrupted; try? self.persist()
                            self.setBusy(false, status: "录音检查失败：没有可用音频，暂不能转写。录屏和截图仍保留。")
                            self.fail(error); self.refresh()
                        }
                    }
                }
            case .failure(let error): self.recordingFailed(error)
            }
        }
    }
    private func recordingFailed(_ error: Error) {
        automaticGate.cancel()
        timer?.invalidate(); timer = nil; drawing?.cancel(); drawing = nil; toolbar.hideAfterRecording(); window.makeKeyAndOrderFront(nil)
        project?.recording?.durationSeconds = recorder.elapsedSeconds
        project?.captureState = .interrupted
        let failure = CaptureFailure(stage: .recording, underlying: error)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let diagnostic = "Point & Tell \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\n" + failure.diagnosticText
        var savedReport = false
        if let store = store {
            do {
                let path = "capture-error-\(UUID().uuidString).txt"
                try Data((diagnostic + "\n").utf8).write(to: store.resolveRelativePath(path), options: .atomic)
                savedReport = true
            } catch { /* The original recording error must remain visible if the disk is unwritable. */ }
        }
        try? persist()
        setBusy(false, status: (failure.errorDescription ?? "录制失败") + "。已写入的文件仍保留，未启动自动转写。")
        refresh()
        let alert = RecordingFailureAlert.make(failure: failure, diagnostic: diagnostic, savedReport: savedReport)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(diagnostic, forType: .string)
        }
    }
    @objc private func refreshMicrophones() {
        guard !busy, !recorder.isBusy else { return }
        let selectedID = microphonePicker.selectedItem?.representedObject as? String
        microphoneChoices = RecordingEngine.microphoneChoices()
        microphonePicker.removeAllItems()
        let defaultName = microphoneChoices.first(where: { $0.isSystemDefault })?.name ?? "无可用设备"
        microphonePicker.addItem(withTitle: "系统默认 · " + defaultName)
        for (index, choice) in microphoneChoices.enumerated() {
            microphonePicker.addItem(withTitle: String(index + 1) + " · " + choice.name + (choice.isSystemDefault ? "（当前默认）" : ""))
            microphonePicker.lastItem?.representedObject = choice.uniqueID
        }
        if let selectedID = selectedID {
            if let item = microphonePicker.itemArray.first(where: { ($0.representedObject as? String) == selectedID }) {
                microphonePicker.select(item)
            } else {
                microphonePicker.addItem(withTitle: "已断开 · 请重新选择麦克风")
                microphonePicker.lastItem?.representedObject = selectedID
                microphonePicker.selectItem(at: microphonePicker.numberOfItems - 1)
            }
        }
        microphonePicker.toolTip = "默认设备会在录制开始时重新读取。选择具体设备后，断开时不会偷偷改用其他麦克风。"
    }

    private func updateMicrophoneMeter() {
        let status = recorder.status
        let power = status.microphoneAveragePowerDBFS.map(Double.init)
        microphoneLevel.doubleValue = min(0, max(-60, power ?? -60))
        let name = status.microphoneName ?? "无麦克风"
        let detail: String
        if !status.audioConnectionEnabled || !status.audioConnectionActive { detail = "音频连接未就绪" }
        else if let power = power { detail = status.microphoneHealth == "noSignal" ? "电平很低，请说话检查" : String(format: "%.0f dBFS", power) }
        else { detail = "等待电平" }
        microphoneLabel.stringValue = name + " · " + detail
        microphoneLabel.toolTip = microphoneLabel.stringValue + (status.microphonePeakPowerDBFS.map { String(format: " · peak %.0f dBFS", $0) } ?? "")
    }

    private func closePlayback() {
        playbackPlayer?.pause()
        (playbackWindow?.contentView as? AVPlayerView)?.player = nil
        playbackPlayer = nil
        playbackWindow?.orderOut(nil)
    }

    @objc private func playRecording() {
        guard !busy, !recorder.isBusy, let store = store, let recording = project?.recording else { return }
        do {
            let movie = try store.resolveRelativePath(recording.relativePath, requireExisting: true)
            playbackPlayer?.pause()
            let player = AVPlayer(url: movie); player.volume = 1; player.isMuted = false
            let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
            view.player = player; view.controlsStyle = .floating
            let playerWindow = playbackWindow ?? NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            playerWindow.title = "本地试听 · 请确认能听见讲话"; playerWindow.isReleasedWhenClosed = false
            playerWindow.delegate = self; playerWindow.contentView = view; playerWindow.center()
            playbackPlayer = player; playbackWindow = playerWindow; playerWindow.makeKeyAndOrderFront(nil)
            player.play()
        } catch { fail(error) }
    }

    @objc private func mark() { captureAnchor(draw: false) }
    @objc private func pen() { captureAnchor(draw: true) }
    private func captureAnchor(draw: Bool) {
        guard recorder.isRecording, !pendingScreenshot, drawing == nil, let store = store else { return }
        pendingScreenshot = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }; defer { self.pendingScreenshot = false }
            guard self.recorder.isRecording else { return }
            do {
                let visual = try VisualCapture.screen(displayID: self.selectedDisplay, belowWindowID: CGWindowID(self.toolbar.windowNumber)); let timestamp = self.recorder.elapsedSeconds
                if draw {
                    guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == self.selectedDisplay }) else {
                        throw NSError(domain: "PointAndTell", code: 24, userInfo: [NSLocalizedDescriptionKey: "录制屏幕已断开，无法打开画笔。请结束录制并重新选择屏幕。"])
                    }
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
        guard !busy, commitTiming() else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.title = "选择 .pointtell 项目文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let chosen = ProjectStore(folderURL: url); let loaded = try chosen.load(); closePlayback(); project = loaded; store = chosen; editingCardID = nil; timingDirty = false
            if project?.groupReviewCards() == true { try persist() }
            if let recording = project?.recording, let movie = try? chosen.resolveRelativePath(recording.relativePath, requireExisting: true) {
                let duration = AVURLAsset(url: movie).duration.seconds
                if duration.isFinite && duration > 0 { project?.recording?.durationSeconds = duration; try persist() }
            }
            if let failed = project?.asrChunks.first(where: { $0.state == .failed }) {
                let details = [failed.errorMessage, failed.diagnostic?.safeSummary].compactMap { $0 }.joined(separator: "\n")
                report("已打开项目。上次转写失败：" + (details.isEmpty ? "请重试失败片段" : details))
            } else {
                report("已打开 \(project?.title ?? "项目")。原始录制与失败片段已保留。")
            }
            refresh() } catch { fail(error) }
    }
    @objc private func revealProject() { if let url = store?.folderURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }

    @objc private func transcribe() { beginTranscription(automatic: false) }
    private func beginTranscription(automatic: Bool, sourceInspection: AudioInspectionReport? = nil) {
        guard workflowReady else { showSetupPreferences(); return }
        guard !busy, commitTiming(), let store = store, let recording = project?.recording else { return }
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkflowReadiness.validAPIKey(key) else { showSetupPreferences(); return }
        guard !automatic || UserDefaults.standard.bool(forKey: SetupWindowController.consentPreference) else { return }
        automaticTranscription = automatic
        closePlayback(); cancelRequested = false; silenceUploadApproved = false
        captureStateBeforeASR = project?.captureState
        cancelASRButton.isEnabled = true; setBusy(true, status: "音频检查：正在本地检查录音，尚未上传…")
        if let inspection = sourceInspection {
            confirmAndPrepareTranscription(apiKey: key, store: store, recording: recording, source: inspection); return
        }
        if project?.asrChunks.isEmpty == false {
            // Saved WAVs are checked individually. A damaged source MOV must
            // not discard a valid saved WAV retry.
            confirmAndPrepareTranscription(apiKey: key, store: store, recording: recording, source: nil)
            return
        }
        do {
            let movie = try store.resolveRelativePath(recording.relativePath, requireExisting: true)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Result { try AudioInspector.inspect(movieURL: movie) }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard !self.cancelRequested else { self.finishASR(cancelled: true); return }
                    switch result {
                    case .success(let inspection): self.confirmAndPrepareTranscription(apiKey: key, store: store, recording: recording, source: inspection)
                    case .failure(let error): self.stopForAudioError(error, stage: "录音检查")
                    }
                }
            }
        } catch { stopForAudioError(error, stage: "录音检查") }
    }

    private func confirmAndPrepareTranscription(apiKey: String, store: ProjectStore, recording: RecordingInfo, source: AudioInspectionReport?) {
        let alert = NSAlert(); alert.messageText = "将本项目的音频发送给阿里云转写？"
        let isQuiet = source?.suspectedSilence == true
        let retryCount = project?.asrChunks.filter { $0.needsTimestampRetry }.count ?? 0
        alert.informativeText = (isQuiet ? "本地检查发现电平很低，可能是静音。此检查只测幅度，不能判断是否有人声；建议取消并先试听。\n\n" : "") + "接收方：maas.qianwenaiapi.com\n模型：qwen-audio-3.0-asr-flash（句/词时间戳）\n发送内容：本项目麦克风录音，按约 3 分钟分片。视频和截图不会上传。服务商可能按用量计费。\n该接口尚未通过真实付费请求验证。"
        if retryCount > 0 {
            alert.informativeText += "\n\n本次会重新发送 \(retryCount) 个缺少完整时间戳的已完成片段，可能再次计费。新结果通过校验后才替换旧结果；手工编辑文字和已选截图会保留，未编辑的空配图卡片会重建。"
        }
        alert.addButton(withTitle: isQuiet ? "仍发送低电平音频并转写" : "发送音频并转写"); alert.addButton(withTitle: "取消")
        if !automaticTranscription || isQuiet || retryCount > 0 {
            guard alert.runModal() == .alertFirstButtonReturn else { finishASR(cancelled: true); return }
        }
        silenceUploadApproved = isQuiet
        project?.queueIncompleteTimestampChunks()
        do { try persist() } catch { finishASR(cancelled: false); fail(error); return }
        if project?.asrChunks.isEmpty == false { processNextChunk(apiKey: apiKey); return }
        do {
            let movie = try store.resolveRelativePath(recording.relativePath, requireExisting: true)
            report("音频提取：将本地录音解码为 16 kHz WAV，尚未上传…")
            chunker.chunk(movieURL: movie, directory: store.folderURL.appendingPathComponent("audio")) { [weak self] result in
                guard let self = self else { return }
                do {
                    let chunks = try result.get()
                    self.project?.asrChunks = chunks.map { ASRChunk(index: $0.index, relativePath: "audio/" + $0.relativePath, startSeconds: $0.startSeconds, durationSeconds: $0.durationSeconds) }
                    try self.persist(); if self.cancelRequested { self.finishASR(cancelled: true) } else { self.processNextChunk(apiKey: apiKey) }
                } catch { self.stopForAudioError(error, stage: "音频提取") }
            }
        } catch { stopForAudioError(error, stage: "音频提取") }
    }

    private func stopForAudioError(_ error: Error, stage: String) {
        finishASR(cancelled: cancelRequested)
        guard !cancelRequested else { return }
        report(stage + "失败：" + (ASRChunk.sanitizedError(error.localizedDescription) ?? "音频无法处理") + "。原文件已保留，尚未发送此片段。")
        fail(error)
    }

    private func processNextChunk(apiKey: String) {
        guard !cancelRequested else { finishASR(cancelled: true); return }
        guard let index = project?.asrChunks.firstIndex(where: { $0.state == .pending || $0.state == .failed }), let store = store else { buildReviewFrames(); return }
        guard let chunk = project?.asrChunks[index] else { return }
        report("WAV 检查：片段 \(chunk.index + 1)，正在确认实际上传文件可解码及电平…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<(AudioInspectionReport, Data), Error> = Result {
                let url = try store.resolveRelativePath(chunk.relativePath, requireExisting: true)
                let inspection = try AudioInspector.inspect(movieURL: url)
                let wav = try Data(contentsOf: url, options: .mappedIfSafe)
                try ASRWAVAudio(wav: wav).validateForRequest()
                return (inspection, wav)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !self.cancelRequested else { self.finishASR(cancelled: true); return }
                do {
                    let (inspection, wav) = try result.get()
                    if inspection.suspectedSilence && !self.silenceUploadApproved {
                        if self.automaticTranscription {
                            self.finishASR(cancelled: true)
                            self.report("自动转写已暂停：片段 \(chunk.index + 1) 电平很低。请先试听，再手动继续转写。录音和已完成结果均已保留。")
                            return
                        }
                        let alert = NSAlert(); alert.messageText = "片段 \(chunk.index + 1) 电平很低，仍要上传吗？"
                        alert.informativeText = inspection.safeSummary + "\n这不是人声检测。安静的讲话也可能触发提示；建议先取消并本地试听。继续会允许本项目本次转写中的低电平片段上传，并可能产生费用。"
                        alert.addButton(withTitle: "本次继续发送低电平片段"); alert.addButton(withTitle: "取消并试听")
                        guard alert.runModal() == .alertFirstButtonReturn else { self.finishASR(cancelled: true); return }
                        self.silenceUploadApproved = true
                    }
                    self.sendChunk(index: index, chunk: chunk, wav: wav, apiKey: apiKey)
                } catch {
                    self.project?.asrChunks[index].state = .failed
                    self.project?.asrChunks[index].errorMessage = ASRChunk.sanitizedError("[WAV inspection] " + error.localizedDescription)
                    self.project?.asrChunks[index].diagnostic = nil
                    try? self.persist(); self.stopForAudioError(error, stage: "WAV 检查")
                }
            }
        }
    }

    private func sendChunk(index: Int, chunk: ASRChunk, wav: Data, apiKey: String) {
        activeChunkID = chunk.id; project?.asrChunks[index].state = .transcribing; project?.asrChunks[index].errorMessage = nil; project?.asrChunks[index].diagnostic = nil
        do {
            try persist()
            let completed = project?.asrChunks.filter { $0.state == .complete }.count ?? 0
            report("Qwen Audio 3.0 转写：片段 \(chunk.index + 1) / \(project?.asrChunks.count ?? 0) · 已完成 \(completed)。等待服务商返回，没有估算进度。")
            asrTask = asr.transcribe(wav: wav, apiKey: apiKey) { [weak self] result in
                guard let self = self else { return }; self.asrTask = nil; self.activeChunkID = nil
                guard self.project?.asrChunks.indices.contains(index) == true else { return }
                switch result {
                case .success(let sentences):
                    do {
                        try self.project?.acceptTranscription(sentences.map { $0.transcriptSegment(chunkOffset: chunk.startSeconds) }, forChunkAt: index)
                    } catch {
                        self.project?.asrChunks[index].state = .failed
                        self.project?.asrChunks[index].errorMessage = ASRError.safeDescription(for: error)
                        self.project?.asrChunks[index].diagnostic = ASRDiagnostic(error: error)
                        try? self.persist(); self.finishASR(cancelled: false); self.fail(error); return
                    }
                case .failure(let error):
                    self.project?.asrChunks[index].state = self.cancelRequested ? .pending : .failed
                    let safe = ASRError.safeDescription(for: error)
                    self.project?.asrChunks[index].errorMessage = safe
                    self.project?.asrChunks[index].diagnostic = ASRDiagnostic(error: error)
                    try? self.persist(); self.finishASR(cancelled: self.cancelRequested)
                    if !self.cancelRequested { self.report(safe); self.fail(NSError(domain: "PointAndTell.ASR", code: 1, userInfo: [NSLocalizedDescriptionKey: safe])) }; return
                }
                do { try self.persist(); self.processNextChunk(apiKey: apiKey) } catch { self.finishASR(cancelled: false); self.fail(error) }
            }
        } catch { project?.asrChunks[index].state = .failed; project?.asrChunks[index].diagnostic = nil; project?.asrChunks[index].errorMessage = ASRChunk.sanitizedError(error.localizedDescription); try? persist(); finishASR(cancelled: false); fail(error) }
    }
    @objc private func cancelASR() { cancelRequested = true; asrTask?.cancel(); if asrTask == nil { report("将在当前本地步骤结束后取消；已完成的音频片段保留。") } }
    private func finishASR(cancelled: Bool) {
        automaticTranscription = false
        let completed = project?.asrChunks.sorted(by: { $0.index < $1.index }).flatMap { $0.sentences } ?? []
        project?.transcripts = completed
        let existing = Set(project?.reviewCards.compactMap { $0.transcriptID } ?? [])
        let partialCards = FrameMatcher.suggestCards(for: completed.filter { !existing.contains($0.id) }, anchors: project?.anchors ?? [])
        project?.reviewCards.append(contentsOf: partialCards)
        project?.groupReviewCards()
        if project?.captureState == .processing { project?.captureState = captureStateBeforeASR ?? .complete }
        try? persist(); cancelASRButton.isEnabled = false; setBusy(false, status: cancelled ? "转写已取消。已完成的片段保留，下次会继续未完成片段。" : "转写处理已停止。请检查片段状态；重试只发送未完成或失败的片段。"); refresh()
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
                self.project?.groupReviewCards()
                self.project?.captureState = self.captureStateBeforeASR ?? .complete; do { try self.persist() } catch { self.fail(error) }
                self.automaticTranscription = false
                self.cancelASRButton.isEnabled = false; self.setBusy(false, status: warning.map { "转写完成，但部分截图失败：\($0)。请手动取图后导出。" } ?? "转写与配图已准备好。请校对文字、时间和图片，再导出。无时间戳的句子需要手动配图。")
                self.refresh(); if !(self.project?.reviewCards.isEmpty ?? true) { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !busy, let id = editingCardID, let index = project?.reviewCards.firstIndex(where: { $0.id == id }) else { return }
        project?.reviewCards[index].text = transcriptEditor.string
        do { try persist(); savedLabel.stringValue = "文字已保存"; updateVisibleCard(at: index) }
        catch { savedLabel.stringValue = "保存失败"; report("保存文字失败：\(error.localizedDescription)") }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === startField || field === endField else { return }
        timingDirty = true; savedLabel.stringValue = "时间待保存"
    }
    @discardableResult private func commitTiming() -> Bool {
        guard timingDirty, let id = editingCardID, let index = project?.reviewCards.firstIndex(where: { $0.id == id }) else { return true }
        let a = startField.stringValue.trimmingCharacters(in: .whitespaces), b = endField.stringValue.trimmingCharacters(in: .whitespaces)
        let start = a.isEmpty ? nil : Double(a), end = b.isEmpty ? nil : Double(b)
        guard (a.isEmpty || start != nil), (b.isEmpty || end != nil),
              start.map({ $0.isFinite && $0 >= 0 }) ?? true, end.map({ $0.isFinite && $0 >= 0 }) ?? true,
              !(start != nil && end != nil && end! < start!) else {
            savedLabel.stringValue = "请检查时间"
            report("时间未保存：请输入有效秒数，结束时间不能早于起始时间。也可清空时间。")
            window.makeFirstResponder(startField); NSSound.beep(); return false
        }
        project?.reviewCards[index].startSeconds = start; project?.reviewCards[index].endSeconds = end
        do { try persist(); timingDirty = false; savedLabel.stringValue = "已保存"; updateVisibleCard(at: index); return true }
        catch { savedLabel.stringValue = "保存失败"; report(error.localizedDescription); return false }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { project?.reviewCards.count ?? 0 }
    private func configure(_ cell: ReviewCardCell, at index: Int) {
        guard let cards = project?.reviewCards, cards.indices.contains(index) else { return }
        let card = cards[index]
        let time = card.startSeconds.map { String(format: "%.1f 秒", $0) } ?? "时间待校对"
        cell.configure(number: index + 1, text: card.text, time: time, images: card.frameIDs.count)
    }
    private func updateVisibleCard(at index: Int) {
        if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ReviewCardCell { configure(cell, at: index) }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ReviewCard")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ReviewCardCell ?? ReviewCardCell(frame: .zero)
        cell.identifier = identifier; configure(cell, at: row); return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy && commitTiming() }
    func tableViewSelectionDidChange(_ notification: Notification) { loadCard() }
    private func loadCard() {
        guard let index = cardIndex, let card = project?.reviewCards[index] else {
            editingCardID = nil; transcriptEditor.string = ""; preview.image = nil; updateInterface(); return
        }
        if editingCardID != card.id { transcriptEditor.undoManager?.removeAllActions() }
        editingCardID = card.id; timingDirty = false
        transcriptEditor.string = card.text
        startField.stringValue = card.startSeconds.map { String(format: "%.3f", $0) } ?? ""
        endField.stringValue = card.endSeconds.map { String(format: "%.3f", $0) } ?? ""
        cardInfo.stringValue = "讲解 \(String(format: "%02d", index + 1))"
        savedLabel.stringValue = "文字自动保存"
        attachmentLabel.stringValue = card.frameIDs.isEmpty ? "尚未配图 · 选择截图后自动保存" : "已配 \(card.frameIDs.count) 张图 · 选择其他截图即替换"
        restoreFrameSelection(); updateInterface()
    }
    @objc private func saveCard() {
        guard !busy, cardIndex != nil, commitTiming() else { return }
        do { try persist(); savedLabel.stringValue = "已保存"; report("卡片已保存到本地项目。") } catch { fail(error) }
    }
    @objc private func addCard() {
        guard !busy, project != nil, commitTiming() else { return }
        let card = ReviewCard(text: ""); project?.reviewCards.append(card)
        do { try persist(); editingCardID = card.id; refresh(); window.makeFirstResponder(transcriptEditor) } catch { fail(error) }
    }
    private func refreshFramePicker() {
        framePicker.removeAllItems()
        for anchor in project?.anchors ?? [] {
            let kind: String
            switch anchor.kind { case .pen: kind = "画笔标注"; case .bookmark: kind = "重点标记"; case .frame: kind = "录屏截图" }
            // Explicit items preserve distinct screenshots even at equal times.
            framePicker.addItem(withTitle: anchor.id.uuidString)
            framePicker.lastItem?.title = String(format: "%.3f 秒 · %@", anchor.timestamp, kind)
            framePicker.lastItem?.representedObject = anchor.id
        }
    }
    private func restoreFrameSelection() {
        if let index = cardIndex, let id = project?.reviewCards[index].frameIDs.first,
           let item = framePicker.itemArray.first(where: { ($0.representedObject as? UUID) == id }) { framePicker.select(item) }
        else { framePicker.select(nil) }
        showSelectedFrame()
    }
    private func showSelectedFrame() {
        if let id = framePicker.selectedItem?.representedObject as? UUID,
           let anchor = project?.anchors.first(where: { $0.id == id }),
           let url = try? store?.resolveRelativePath(anchor.imageRelativePath, requireExisting: true) {
            preview.image = NSImage(contentsOf: url)
        } else { preview.image = nil }
        previewEmpty.isHidden = preview.image != nil
        updateInterface()
    }
    @objc private func selectFrame() {
        guard !busy, !recorder.isBusy, let index = cardIndex,
              project?.reviewCards[index].id == editingCardID,
              let id = framePicker.selectedItem?.representedObject as? UUID,
              project?.anchors.contains(where: { $0.id == id }) == true else { restoreFrameSelection(); return }
        guard commitTiming() else { restoreFrameSelection(); return }
        let previous = project?.reviewCards[index].frameIDs ?? []
        project?.reviewCards[index].frameIDs = [id]
        do {
            try persist(); loadCard(); updateVisibleCard(at: index); savedLabel.stringValue = "配图已保存"
        } catch {
            project?.reviewCards[index].frameIDs = previous
            restoreFrameSelection(); savedLabel.stringValue = "配图保存失败"; fail(error)
        }
    }
    @objc private func clearFrames() { guard !busy, commitTiming(), let index = cardIndex else { return }; project?.reviewCards[index].frameIDs = []; do { try persist(); loadCard(); updateVisibleCard(at: index) } catch { fail(error) } }
    @objc private func extractManualFrame() {
        guard !busy, commitTiming(), let index = cardIndex, let store = store, let recording = project?.recording, let timestamp = Double(frameTimeField.stringValue), timestamp.isFinite, timestamp >= 0, timestamp <= recording.durationSeconds else { report("请选择卡片，并输入录制范围内的秒数。"); return }
        do { let (image, actual) = try VisualCapture.movieFrame(url: store.resolveRelativePath(recording.relativePath, requireExisting: true), at: timestamp); try addAnchor(image: image, timestamp: actual, kind: .frame, store: store); if let id = project?.anchors.last?.id { project?.reviewCards[index].frameIDs.append(id) }; try persist(); refresh(); loadCard() } catch { fail(error) }
    }
    @objc private func exportHTML() { export(bundle: false) }
    @objc private func exportBundle() { export(bundle: true) }
    private func export(bundle: Bool) {
        guard !busy, commitTiming(), let project = project, let store = store else { return }
        guard !project.reviewCards.isEmpty || !project.transcripts.isEmpty else { report("请先转写或添加讲解卡片，再导出。"); return }
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

final class WindowBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
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
