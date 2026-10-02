#if os(macOS)
import AppKit
import PointAndTellCore

enum RecordingFailureAlert {
    static func make(failure: CaptureFailure, diagnostic: String, savedReport: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.errorDescription ?? "录制失败"
        alert.informativeText = failure.stage.suggestion + (savedReport
            ? "\n诊断信息已保存在项目文件夹的 capture-error 文件中。" : "")
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "复制诊断")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = diagnostic
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert
    }
}
#endif
