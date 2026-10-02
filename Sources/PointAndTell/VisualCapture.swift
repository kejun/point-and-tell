#if os(macOS)
import AppKit
import AVFoundation
import PointAndTellCore

struct CapturedVisual {
    let image: CGImage
    let pointer: NormalizedPoint?
}

enum VisualCapture {
    static func screen(displayID: CGDirectDisplayID) throws -> CapturedVisual {
        guard let image = CGDisplayCreateImage(displayID) else {
            throw NSError(domain: "PointAndTell", code: 20, userInfo: [NSLocalizedDescriptionKey: "无法读取屏幕。请在系统偏好设置 → 安全性与隐私 → 屏幕录制中允许 Point & Tell，然后重新打开应用。"])
        }
        let rect = CGDisplayBounds(displayID)
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
        let rep = NSBitmapImageRep(cgImage: output)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PointAndTell", code: 21, userInfo: [NSLocalizedDescriptionKey: "无法编码截图"])
        }
        try png.write(to: url, options: .atomic)
    }

    static func movieFrame(url: URL, at seconds: Double) throws -> (CGImage, Double) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        generator.requestedTimeToleranceBefore = .zero
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

final class DrawingOverlay: NSObject {
    private let window: NSWindow
    private let controls: NSPanel
    private let canvas: DrawingCanvas
    private let completion: (Result<CGImage?, Error>) -> Void
    private var finished = false
    init(image: CGImage, screen: NSScreen, completion: @escaping (Result<CGImage?, Error>) -> Void) {
        self.completion = completion
        canvas = DrawingCanvas(image: image, frame: NSRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = canvas
        window.isReleasedWhenClosed = false
        controls = NSPanel(contentRect: NSRect(x: screen.frame.midX - 255, y: screen.frame.maxY - 82, width: 510, height: 54), styleMask: [.titled], backing: .buffered, defer: false)
        controls.title = "标注冻结截图 · 语音继续录制"
        controls.level = .modalPanel
        controls.isReleasedWhenClosed = false
        super.init()
        let row = NSStackView(views: [button("撤销", #selector(undo)), button("清空", #selector(clear)), button("保存并继续", #selector(done)), button("取消标注", #selector(cancel))])
        row.spacing = 10; row.orientation = .horizontal; row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        controls.contentView = row
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func show() { window.orderFrontRegardless(); controls.orderFrontRegardless() }
    @objc private func undo() { canvas.undoStroke() }
    @objc private func clear() { canvas.clearStrokes() }
    @objc func done() { do { finish(.success(try canvas.bakedImage())) } catch { finish(.failure(error)) } }
    @objc func cancel() { finish(.success(nil)) }
    private func finish(_ result: Result<CGImage?, Error>) { guard !finished else { return }; finished = true; controls.close(); window.close(); completion(result) }
}
#endif
