import AppKit
import WebKit

/// The user manual (a styled HTML page bundled as Resources/manual.html),
/// shown in its own window from the Info menu.
@MainActor
final class HelpWindowController: NSObject, WKNavigationDelegate {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    /// The "i" key: open the manual, or close it if it's already showing.
    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil) } else { show() }
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let url = manualURL() else {
            let alert = NSAlert()
            alert.messageText = "Manual not found"
            alert.informativeText = "The bundled manual (manual.html) is missing from this build."
            alert.runModal()
            return
        }

        // Size to the user's screen: the usable area (menu bar and Dock
        // excluded), capped so the text column doesn't get absurdly wide.
        let usable = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1150, usable.width * 0.85),
                          height: usable.height * 0.90)
        let web = WKWebView(frame: NSRect(origin: .zero, size: size))
        web.navigationDelegate = self
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        let w = NSWindow(contentRect: web.frame,
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "LED OCD — Manual"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func manualURL() -> URL? {
        if let u = Bundle.main.url(forResource: "manual", withExtension: "html") { return u }
        // Development fallback (running the bare binary via `swift run`).
        let dev = URL(fileURLWithPath: "docs/manual.html",
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // Keep the manual itself in-window (including its #anchor navigation), but
    // send real web links (e.g. ledocd.com) to the user's browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
