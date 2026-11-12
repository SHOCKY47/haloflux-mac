import AppKit
import WebKit

final class HaloWebView: WKWebView, WKNavigationDelegate {
    var onReady: (() -> Void)?
    private var isPaused = false

    init(frame: NSRect, compact: Bool = false, liveAgents: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let rate = UserDefaults.standard.object(forKey: "motionRate") as? Double ?? 0.25
        config.userContentController.addUserScript(WKUserScript(source: "window.haloMotionRate=\(rate);window.haloOrcaEnabled=\(liveAgents);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: "window.haloErrors=[];window.addEventListener('error',e=>haloErrors.push(e.message));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: "window.wallpaperPropertyListener?.applyUserProperties({music:{value:false},showui:{value:\(!compact)}});", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        super.init(frame: frame, configuration: config)
        autoresizingMask = [.width, .height]
        navigationDelegate = self
        underPageBackgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:compact:liveAgents:)") }
    func loadAnimation(from bundle: Bundle, page: String = "index.html") {
        guard let resource = bundle.resourceURL else { return }
        loadFileURL(resource.appendingPathComponent(page), allowingReadAccessTo: resource)
    }
    func setPaused(_ value: Bool) {
        isPaused = value
        evaluateJavaScript("if(window.haloSetPaused){window.haloSetPaused(\(value));}else{window.wallpaperPropertyListener?.setPaused(\(value));}")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setPaused(isPaused)
        evaluateJavaScript("window.dispatchEvent(new Event('resize'));if(typeof resizeAll==='function')resizeAll();")
        onReady?()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
}
