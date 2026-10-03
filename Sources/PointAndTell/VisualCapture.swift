#if os(macOS)
import AppKit
import AVFoundation
import PointAndTellCore

struct CapturedVisual {
    let image: CGImage
    let pointer: NormalizedPoint?
}

enum VisualCapture {
    static func screen(displayID: CGDirectDisplayID, belowWindowID: CGWindowID? = nil) throws -> CapturedVisual {
        let rect = CGDisplayBounds(displayID)
        // Composite below the HUD instead of hiding it during a bookmark or
        // throughout annotation. The stop button remains available throughout.
        let capture = belowWindowID.map {
            CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, $0, .bestResolution)
        } ?? CGDisplayCreateImage(displayID)
        guard let image = capture else {
            throw NSError(domain: "PointAndTell", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法读取屏幕。请在系统偏好设置 → 安全性与隐私 → 屏幕录制中允许 Point & Tell，然后重新打开应用。"])
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        let point: NormalizedPoint? = rect.contains(location) ? NormalizedPoint(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height) : nil
        return CapturedVisual(image: image, pointer: point)
    }

    static func save(_ image: CGImage, to url: URL, pointer: NormalizedPoint? = nil) throws {
        let output: CGImage
        if let point = pointer, let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let radius = max(10.0, Double(image.width) / 120)
            let x = point.x * Double(image.width), y = (1 - point.y) * Double(image.height)
            context.setStrokeColor(NSColor.systemYellow.cgColor)
            context.setLineWidth(max(3, Double(image.width) / 500))
            context.strokeEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            output = context.makeImage() ?? image
        } else { output = image }
        // Bound on-disk image dimensions after baking annotations, while keeping
        // pointer/pen geometry derived from the original Retina screenshot.
        let scale = min(1.0, min(1920.0 / Double(output.width), 1080.0 / Double(output.height)))
        var bounded = output
        if scale < 1, let context = CGContext(data: nil, width: max(1, Int(Double(output.width) * scale)), height: max(1, Int(Double(output.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(output, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            bounded = context.makeImage() ?? output
        }
        let rep = NSBitmapImageRep(cgImage: bounded)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PointAndTell", code: 21, userInfo: [NSLocalizedDescriptionKey: "无法编码截图"])
        }
        try png.write(to: url, options: .atomic)
    }

    static func movieFrame(url: URL, at seconds: Double) throws -> (CGImage, Double) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        var actual = CMTime.zero
        let image = try generator.copyCGImage(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600), actualTime: &actual)
        return (image, actual.seconds)
    }
}

final class DrawingCanvas: NSView {
    let image: CGImage
    private var strokes: [[NSPoint]] = []
    init(image: CGImage, frame: NSRect) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var strokeCount: Int { strokes.count }
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { onSave?() }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        NSColor.systemRed.setStroke()
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            for point in stroke.dropFirst() { path.line(to: point) }
            if stroke.count == 1 { path.line(to: NSPoint(x: stroke[0].x + 0.1, y: stroke[0].y + 0.1)) }
            path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { strokes.append([convert(event.locationInWindow, from: nil)]); needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { guard !strokes.isEmpty else { return }; strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    func undoStroke() { if !strokes.isEmpty { strokes.removeLast(); needsDisplay = true } }
    func clearStrokes() { strokes.removeAll(); needsDisplay = true }
    func bakedImage() throws -> CGImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "PointAndTell", code: 22, userInfo: [NSLocalizedDescriptionKey: "无法生成标注截图"])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(image.width) / bounds.width, y: CGFloat(image.height) / bounds.height)
        draw(bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let result = rep.cgImage else { throw NSError(domain: "PointAndTell", code: 23) }
        return result
    }
}

/// A regular borderless NSWindow cannot become key. Pen input needs its own
/// key-capable nonactivating panel, independent of the non-key recording HUD.
final class DrawingInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DrawingOverlay: NSObject {
    private let window: DrawingInputPanel
    private let controls: NSPanel
    private let canvas: DrawingCanvas
    private let completion: (Result<CGImage?, Error>) throws -> Void
    private var finished = false
    init(image: CGImage, screen: NSScreen, completion: @escaping (Result<CGImage?, Error>) throws -> Void) {
        self.completion = completion
        canvas = DrawingCanvas(image: image, frame: NSRect(origin: .zero, size: screen.frame.size))
        window = DrawingInputPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: RecordingToolbarPanel.recordingLevel.rawValue - 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = canvas
        window.hidesOnDeactivate = false
        window.canHide = false
        window.becomesKeyOnlyIfNeeded = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        controls = NSPanel(contentRect: NSRect(x: screen.frame.midX - 255, y: screen.frame.maxY - 82, width: 510, height: 54), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        controls.title = "标注冻结截图 · 语音继续录制"
        controls.level = NSWindow.Level(rawValue: RecordingToolbarPanel.recordingLevel.rawValue - 1)
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        controls.hidesOnDeactivate = false
        controls.canHide = false
        controls.becomesKeyOnlyIfNeeded = true
        controls.isReleasedWhenClosed = false
        super.init()
        let row = NSStackView(views: [button("撤销", #selector(undo)), button("清空", #selector(clear)), button("保存并继续", #selector(done)), button("取消标注", #selector(cancel))])
        row.spacing = 10; row.orientation = .horizontal; row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        controls.contentView = row
        canvas.onSave = { [weak self] in self?.done() }
        canvas.onCancel = { [weak self] in self?.cancel() }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        controls.orderFrontRegardless()
    }
    @objc private func undo() { canvas.undoStroke() }
    @objc private func clear() { canvas.clearStrokes() }
    @discardableResult @objc func done() -> Bool {
        do { return finish(.success(try canvas.bakedImage())) } catch { return finish(.failure(error)) }
    }
    @objc func cancel() { _ = finish(.success(nil)) }
    private func finish(_ result: Result<CGImage?, Error>) -> Bool {
        guard !finished else { return true }
        do { try completion(result) }
        catch {
            let alert = NSAlert(); alert.messageText = "标注保存失败"
            alert.informativeText = error.localizedDescription + "\n笔迹仍保留，请修复后重新保存，或明确取消标注。"
            alert.runModal(); return false
        }
        finished = true; controls.close(); window.close(); return true
    }
}

extension DrawingOverlay {
    /// Dispatch mouse events through AppKit's window routing, then exercise the
    /// real controls and PNG baking. No capture, microphone or accessibility grant.
    static func verifyInteraction(directory: URL, toolbar: RecordingToolbarPanel) throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "PointAndTell.PenSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        guard let screen = NSScreen.main,
              let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "PointAndTell.PenSmoke", code: 2)
        }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let image = context.makeImage()!
        var saved: CGImage?; var completions = 0
        let overlay = DrawingOverlay(image: image, screen: screen) { result in
            completions += 1; saved = try? result.get()
        }
        toolbar.showForRecording(on: screen); overlay.show()
        defer { overlay.cancel(); toolbar.hideAfterRecording() }
        try require(overlay.window.canBecomeKey && overlay.window.isKeyWindow, "Pen panel did not become key")
        try require(overlay.window.firstResponder === overlay.canvas && overlay.canvas.acceptsFirstMouse(for: nil), "Pen canvas does not receive the first stroke")
        try require(toolbar.isVisible && toolbar.level.rawValue > overlay.controls.level.rawValue, "Recording controls disappeared behind pen mode")
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "PointAndTell.PenSmoke", code: 3)
            }
            overlay.window.sendEvent(event)
        }
        func stroke() throws {
            try event(.leftMouseDown, x: 200, y: 200)
            try event(.leftMouseDragged, x: 350, y: 300)
            try event(.leftMouseUp, x: 350, y: 300)
        }
        func click(_ title: String) throws {
            guard let stack = overlay.controls.contentView as? NSStackView,
                  let button = stack.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw NSError(domain: "PointAndTell.PenSmoke", code: 4)
            }
            button.performClick(nil)
        }
        try stroke(); try require(overlay.canvas.strokeCount == 1, "Mouse drag did not draw")
        try click("撤销"); try require(overlay.canvas.strokeCount == 0, "Undo failed")
        try stroke(); try click("清空"); try require(overlay.canvas.strokeCount == 0, "Clear failed")
        try stroke(); try click("保存并继续"); overlay.done()
        try require(completions == 1 && saved != nil, "Save must finish exactly once")
        try require(!overlay.window.isVisible && !overlay.controls.isVisible && toolbar.isVisible, "Pen cleanup hid the recording HUD")
        if let saved = saved {
            let pixels = NSBitmapImageRep(cgImage: saved)
            var redPixels = 0
            for y in 0..<pixels.pixelsHigh { for x in 0..<pixels.pixelsWide {
                if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.7 && color.greenComponent < 0.5 && color.blueComponent < 0.5 { redPixels += 1 }
            } }
            try require(redPixels > 20, "Saved PNG contains no drawn red stroke")
            try VisualCapture.save(saved, to: directory.appendingPathComponent("pen-drawing.png"))
        }
        var cancelled = 0
        let second = DrawingOverlay(image: image, screen: screen) { result in
            if case .success(nil) = result { cancelled += 1 }
        }
        second.show()
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: second.window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            second.window.sendEvent(escape)
        }
        try require(cancelled == 1, "Escape did not reach the drawing canvas")
        second.cancel()
        try require(cancelled == 1 && !second.window.isVisible && toolbar.isVisible, "Cancel must finish once without hiding the HUD")
        print("PEN_SMOKE_OK · window-dispatched first stroke/drag, undo, clear, saved PNG pixels, cancellation and HUD visibility")
    }
}
#endif
