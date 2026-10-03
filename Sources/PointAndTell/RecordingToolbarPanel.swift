#if os(macOS)
import AppKit

/// A nonactivating recording HUD. Ordering it never takes keyboard focus away
/// from the application being demonstrated. Stop observing as soon as it ends.
final class RecordingToolbarPanel: NSPanel {
    static let recordingLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var visibilityTimer: Timer?
    private(set) var recordingVisible = false

    init() {
        super.init(contentRect: NSRect(x: 60, y: 60, width: 930, height: 60),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Point & Tell · 录制中"
        level = Self.recordingLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        canHide = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }

    func showForRecording(on screen: NSScreen?) {
        if !recordingVisible, let frame = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: frame.minX + max(0, (frame.width - self.frame.width) / 2), y: frame.minY + 24))
        }
        recordingVisible = true
        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.maintainVisibility()
                })
            }
        }
        if visibilityTimer == nil {
            let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.maintainVisibility() }
            RunLoop.main.add(timer, forMode: .common)
            visibilityTimer = timer
        }
        maintainVisibility()
    }
    private func maintainVisibility() {
        guard recordingVisible else { return }
        level = Self.recordingLevel
        orderFrontRegardless()
    }
    func hideAfterRecording() {
        recordingVisible = false
        visibilityTimer?.invalidate(); visibilityTimer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        orderOut(nil)
    }
    deinit {
        visibilityTimer?.invalidate()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
#endif
