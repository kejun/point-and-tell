#if os(macOS)
import AppKit

/// Small AppKit primitives shared by the workspace. Semantic colors resolve in
/// the view's current appearance; no fixed light-mode layer backgrounds.
enum InterfaceStyle {
    static let primaryFill = NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.31, alpha: 1)
    static var accent: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.37, green: 0.79, blue: 0.70, alpha: 1)
                : NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.31, alpha: 1)
        }
    }
    static func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    static func symbol(_ name: String, size: CGFloat = 16) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = accent
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: size), view.heightAnchor.constraint(equalToConstant: size)])
        return view
    }
    static func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; stack.distribution = .fill
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
    static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

/// A native NSButtonCell with a predictable solid brand bezel. AppKit may ignore
/// bezelColor for rounded buttons on older macOS or inactive windows; drawing
/// only the bezel/content keeps native action, focus and accessibility behavior.
final class PrimaryButtonCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let color = isHighlighted
            ? InterfaceStyle.primaryFill.shadow(withLevel: 0.18) ?? InterfaceStyle.primaryFill
            : InterfaceStyle.primaryFill
        color.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let text = NSMutableAttributedString(attributedString: title)
        text.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.65),
                          range: NSRange(location: 0, length: text.length))
        return super.drawTitle(text, withFrame: frame, in: controlView)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Let AppKit position/scale the symbol using its alignment metrics, then
        // tint only that isolated drawing. Re-rasterizing a symbol at image.size
        // loses those metrics and can squash circular icons.
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        super.drawImage(image, withFrame: frame, in: controlView)
        context.setBlendMode(.sourceIn)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(controlView.bounds)
        context.setBlendMode(.normal)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

final class SurfaceView: NSView {
    var fill: NSColor = .controlBackgroundColor
    var radius: CGFloat = 12
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class FlippedContentView: NSView { override var isFlipped: Bool { true } }

/// Sidebar-style list row with a real native selection background and separate
/// title/metadata labels, so long feedback doesn't become one dense text block.
final class ReviewCardCell: NSTableCellView {
    private let heading = InterfaceStyle.text("", size: 12, weight: .semibold)
    private let summary = InterfaceStyle.text("", size: 12)
    private let metadata = InterfaceStyle.text("", size: 10, color: .secondaryLabelColor)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.maximumNumberOfLines = 1; summary.maximumNumberOfLines = 2; metadata.maximumNumberOfLines = 1
        heading.lineBreakMode = .byTruncatingTail; summary.lineBreakMode = .byTruncatingTail
        let stack = InterfaceStyle.column([heading, summary, metadata], spacing: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            heading.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            summary.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            metadata.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
    func configure(number: Int, text: String, time: String, images: Int) {
        heading.stringValue = String(format: "%02d", number) + "  ·  " + time
        summary.stringValue = text.isEmpty ? "添加讲解文字…" : text
        metadata.stringValue = "\(images) 张配图" + (text.isEmpty ? " · 待补充" : "")
        setAccessibilityLabel("卡片 \(number)，\(time)，\(images) 张配图，\(text)")
    }
}
#endif
