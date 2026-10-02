import AppKit
import WebKit

// Render the app's actual exported fixture in macOS WebKit. No remote URL,
// credentials, microphone, screen capture, or third-party browser dependency.
final class ExportPreview: NSObject, WKNavigationDelegate {
    let input: URL
    let output: URL
    let window: NSWindow
    let web: WKWebView
    var compact = false

    init(input: URL, output: URL) {
        self.input = input; self.output = output
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 1000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 1000))
        super.init()
        window.contentView = web; web.navigationDelegate = self
    }
    func start() {
        window.orderFrontRegardless()
        web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { capture() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { exit(1) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { exit(1) }
    func capture() {
        web.evaluateJavaScript("""
            (() => {
                const groups = [...document.querySelectorAll('.moment')];
                if (groups.length !== 2) return false;
                if (groups[0].querySelector('.transcript').textContent !== '请查看右上角的按钮。') return false;
                if (groups[1].querySelector('.transcript').textContent !== '然后确认保存后的状态。') return false;
                if (!groups.every(g => {const i=g.querySelector('img'); return i && i.complete && i.naturalWidth>0;})) return false;
                if (document.documentElement.scrollWidth > innerWidth) return false;
                return groups.every(g => {
                    const text = g.querySelector('.passage').getBoundingClientRect();
                    const image = g.querySelector('.screenshots').getBoundingClientRect();
                    return innerWidth > 720 ? text.right <= image.left : text.bottom <= image.top;
                });
            })()
            """) { result, error in
            guard error == nil, result as? Bool == true else { fputs("EXPORT_LAYOUT_FAILED\n", stderr); exit(2) }
            self.web.takeSnapshot(with: nil) { image, error in
                guard error == nil, let tiff = image?.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
                do { try png.write(to: self.output.appendingPathComponent(self.compact ? "export-compact.png" : "export-desktop.png")) }
                catch { exit(4) }
                if self.compact { print("EXPORT_WEBKIT_OK · desktop/compact, speech-image grouping, embedded images, no overflow"); exit(0) }
                self.compact = true
                self.window.setContentSize(NSSize(width: 390, height: 1200))
                self.web.frame = NSRect(x: 0, y: 0, width: 390, height: 1200)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.capture() }
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard CommandLine.arguments.count == 3 else { exit(64) }
let renderer = ExportPreview(input: URL(fileURLWithPath: CommandLine.arguments[1]),
                             output: URL(fileURLWithPath: CommandLine.arguments[2]))
DispatchQueue.main.async { renderer.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fputs("EXPORT_RENDER_TIMEOUT\n", stderr); exit(5) }
app.run()
