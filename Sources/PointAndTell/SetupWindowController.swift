#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import PointAndTellCore

final class SetupWindowController: NSWindowController, NSTextFieldDelegate {
    static let consentPreference = "PointAndTell.AutomaticAudioUploadConsent.v1"
    static let completedPreference = "PointAndTell.SetupCompleted.v1"
    let keyField = NSSecureTextField(string: "")
    let consent = NSButton(checkboxWithTitle: "录制结束后，自动上传音频并转写", target: nil, action: nil)
    let continueButton = NSButton(title: "完成设置，进入工作区", target: nil, action: nil)
    private let screenStatus = InterfaceStyle.text("", size: 12, color: .secondaryLabelColor)
    private let microphoneStatus = InterfaceStyle.text("", size: 12, color: .secondaryLabelColor)
    private let keyStatus = InterfaceStyle.text("", size: 11, color: .secondaryLabelColor)
    private let message = InterfaceStyle.text("", size: 11, color: .secondaryLabelColor)
    private let screenButton = NSButton(title: "授权屏幕录制", target: nil, action: nil)
    private let microphoneButton = NSButton(title: "授权麦克风", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存密钥", target: nil, action: nil)
    private let permissions: (String, Bool) -> WorkflowReadiness
    private let saveKey: (String, @escaping (Result<Void, Error>) -> Void) -> Void
    private let completion: (String) -> Void
    private var savedKey = ""
    private var saving = false
    private var loading = false
    private var completed = false
    private var observer: NSObjectProtocol?

    static func readiness(key: String, consent: Bool) -> WorkflowReadiness {
        WorkflowReadiness(screenPermission: CGPreflightScreenCaptureAccess(),
            microphonePermission: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            hasDisplay: !NSScreen.screens.isEmpty, hasMicrophone: !RecordingEngine.microphoneChoices().isEmpty,
            hasAPIKey: WorkflowReadiness.validAPIKey(key), automaticUploadConsent: consent)
    }

    init(key: String, consentGranted: Bool,
         permissions: @escaping (String, Bool) -> WorkflowReadiness = SetupWindowController.readiness,
         saveKey: @escaping (String, @escaping (Result<Void, Error>) -> Void) -> Void = APIKeyStore.saveAsync,
         completion: @escaping (String) -> Void) {
        self.permissions = permissions; self.saveKey = saveKey; self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "开始使用 Point & Tell"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 620)
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        savedKey = key; keyField.stringValue = key; consent.state = consentGranted ? .on : .off
        buildInterface(); refreshState(); window.center()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshState() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }

    func restore(key: String?, error: Error? = nil) {
        loading = false; savedKey = key ?? ""; keyField.stringValue = savedKey
        message.stringValue = error?.localizedDescription ?? "完成以上设置后，就可以开始录制。"
        refreshState()
    }
    func setLoading() { loading = true; message.stringValue = "正在读取 macOS 钥匙串…"; refreshState() }
    func controlTextDidChange(_ notification: Notification) { refreshState() }
    @objc func refreshState() {
        let ready = permissions(keyField.stringValue, consent.state == .on)
        screenStatus.stringValue = !ready.hasDisplay ? "未检测到可录制屏幕" : ready.screenPermission ? "已允许 · 可以录制屏幕" : "未允许 · 需要在系统设置中开启"
        microphoneStatus.stringValue = !ready.hasMicrophone ? "未检测到麦克风，请连接设备后重新检查" : ready.microphonePermission ? "已允许 · 麦克风可用" : "未允许 · 需要访问麦克风"
        screenButton.isEnabled = !ready.screenPermission && !saving
        microphoneButton.isEnabled = !ready.microphonePermission && !saving
        screenButton.title = ready.screenPermission ? "已允许" : "授权 / 打开设置"
        microphoneButton.title = ready.microphonePermission ? "已允许" : "授权 / 打开设置"
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        keyStatus.stringValue = !ready.hasAPIKey ? "请填写单行 API Key" : key == savedKey ? "已保存到钥匙串 · 服务权限和额度在首次转写时确认" : "格式有效 · 完成设置时安全保存到钥匙串"
        keyField.isEnabled = !saving && !loading
        consent.isEnabled = !saving && !loading
        saveButton.isEnabled = ready.hasAPIKey && key != savedKey && !saving && !loading
        continueButton.isEnabled = ready.canEnterWorkspace && !saving && !loading && !completed
    }
    @objc private func requestScreen() {
        if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
        message.stringValue = "如果系统提示退出并重新打开，请先保存密钥，再重开应用。"
        refreshState()
    }
    @objc private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshState() }
            }
        } else { openPrivacy("Privacy_Microphone") }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func saveOnly() { persistKey(enterWorkspace: false) }
    @objc func finishSetup() {
        guard permissions(keyField.stringValue, consent.state == .on).canEnterWorkspace else { refreshState(); return }
        persistKey(enterWorkspace: true)
    }
    private func persistKey(enterWorkspace: Bool) {
        guard !saving, !loading, !completed else { return }
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkflowReadiness.validAPIKey(key) else { refreshState(); return }
        saving = true; message.stringValue = "正在安全保存密钥…"; refreshState()
        saveKey(key) { [weak self] result in
            guard let self = self else { return }
            self.saving = false
            switch result {
            case .success:
                self.savedKey = key
                self.message.stringValue = "密钥已保存到 macOS 钥匙串。"
                if enterWorkspace && self.permissions(key, self.consent.state == .on).canEnterWorkspace {
                    self.completed = true; self.completion(key)
                }
            case .failure(let error): self.message.stringValue = error.localizedDescription
            }
            self.refreshState()
        }
    }
    private func buildInterface() {
        guard let window = window else { return }
        let root = WindowBackgroundView(); window.contentView = root
        keyField.placeholderString = "输入阿里云 API Key"; keyField.delegate = self
        keyField.setAccessibilityLabel("转写 API Key，保存到 macOS 钥匙串")
        consent.target = self; consent.action = #selector(refreshState)
        screenButton.target = self; screenButton.action = #selector(requestScreen)
        microphoneButton.target = self; microphoneButton.action = #selector(requestMicrophone)
        saveButton.target = self; saveButton.action = #selector(saveOnly)
        continueButton.target = self; continueButton.action = #selector(finishSetup)
        continueButton.keyEquivalent = "\r"; continueButton.bezelColor = InterfaceStyle.accent
        for button in [screenButton, microphoneButton, saveButton, continueButton] { button.bezelStyle = .rounded }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 12; stack.alignment = .centerY
            return stack
        }
        func card(_ title: String, contents: [NSView]) -> NSView {
            let surface = SurfaceView()
            let column = InterfaceStyle.column([InterfaceStyle.text(title, size: 14, weight: .semibold)] + contents, spacing: 10)
            InterfaceStyle.pin(column, to: surface, inset: 16)
            return surface
        }
        let introduction = InterfaceStyle.column([
            InterfaceStyle.text("准备好，再开始讲解", size: 26, weight: .bold),
            InterfaceStyle.text("完成三项设置。之后，新建录制 → 结束录制 → 自动转写与配图。", size: 13, color: .secondaryLabelColor)
        ], spacing: 8)
        let screen = card("01  屏幕录制", contents: [row([screenStatus, InterfaceStyle.spacer(), screenButton])])
        let microphone = card("02  麦克风", contents: [row([microphoneStatus, InterfaceStyle.spacer(), microphoneButton])])
        let api = card("03  语音识别", contents: [
            InterfaceStyle.text("qwen-audio-3.0-asr-flash · 完整句 / 词时间戳", size: 12, color: .secondaryLabelColor),
            row([keyField, saveButton]), keyStatus
        ])
        keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        let disclosure = InterfaceStyle.text("接收方：maas.qianwenaiapi.com（阿里云）。仅发送本次麦克风录音，可能按用量计费。录屏和截图保留在本地；API Key 仅存入本机钥匙串。", size: 11, color: .secondaryLabelColor)
        let body = InterfaceStyle.column([introduction, screen, microphone, api, consent, disclosure], spacing: 18)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = FlippedContentView(); scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        InterfaceStyle.pin(body, to: document, inset: 4)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let refresh = NSButton(title: "重新检查", target: self, action: #selector(refreshState)); refresh.bezelStyle = .rounded
        let footer = row([refresh, InterfaceStyle.spacer(), continueButton])
        message.maximumNumberOfLines = 3
        let layout = InterfaceStyle.column([scroll, InterfaceStyle.separator(), message, footer], spacing: 12)
        InterfaceStyle.pin(layout, to: root, inset: 24)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
    }
}
#endif
