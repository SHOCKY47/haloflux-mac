import AppKit
import WebKit

// A nib-free app must instantiate and retain its delegate explicitly.
@main
enum HaloFluxMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = HaloFluxDesktopApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class HaloFluxDesktopApp: NSObject, NSApplicationDelegate {
    private static let orcaBundleIdentifier = "com.stablyai.orca"
    private var desktopWindows: [NSWindow] = []
    private var desktopLayoutKey = ""
    private var preview: NSWindow?
    private var statusItem: NSStatusItem?
    private var records: [[String: Any]] = []
    private var diagnosticDirectory: URL?
    private var speedItems: [NSMenuItem] = []
    private let orcaBridge = OrcaStateBridge()
    private var orcaState: [String: Any]?
    private var sessionLocked = false
    private var displaySleeping = false

    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = argument("--diagnose-dir") {
            diagnosticDirectory = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: diagnosticDirectory!, withIntermediateDirectories: true)
        }
        makeMenu()
        orcaBridge.onUpdate = { [weak self] state in
            guard let self else { return }
            self.orcaState = state
            self.sceneWebViews.forEach { self.deliver(state, to: $0) }
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(orcaApplicationChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(orcaApplicationChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        updateOrcaAvailability()
        orcaBridge.start()
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(presentationChanged(_:)), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(presentationChanged(_:)), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(presentationChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(presentationChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        if CommandLine.arguments.contains("--preview") { showPreview() }
        else {
            showDesktop()
            NotificationCenter.default.addObserver(self, selector: #selector(showDesktop), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
    }

    private var sceneWebViews: [HaloWebView] {
        (desktopWindows + (preview.map { [$0] } ?? [])).flatMap { window in
            ([window.contentView].compactMap { $0 } + (window.contentView?.subviews ?? [])).compactMap { $0 as? HaloWebView }
        }
    }

    private func deliver(_ state: [String: Any], to web: WKWebView) {
        // Structured arguments keep workspace names and agent titles out of code.
        web.callAsyncJavaScript("window.haloReceiveOrcaState?.(state)", arguments: ["state": state], in: nil, in: .page, completionHandler: nil)
    }

    private func sceneReady(_ web: WKWebView, window: NSWindow) {
        (web as? HaloWebView)?.setPaused(sessionLocked || displaySleeping)
        if let orcaState { deliver(orcaState, to: web) }
        diagnose(web, window: window)
    }

    private func updateOrcaAvailability() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.orcaBundleIdentifier)
            .contains { !$0.isTerminated }
        orcaBridge.setSourceAvailable(running)
    }

    @objc private func orcaApplicationChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.orcaBundleIdentifier else { return }
        DispatchQueue.main.async { [weak self] in self?.updateOrcaAvailability() }
    }

    @objc private func presentationChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch notification.name {
            case NSNotification.Name("com.apple.screenIsLocked"): self.sessionLocked = true
            case NSNotification.Name("com.apple.screenIsUnlocked"): self.sessionLocked = false
            case NSWorkspace.screensDidSleepNotification: self.displaySleeping = true
            case NSWorkspace.screensDidWakeNotification: self.displaySleeping = false
            default: return
            }
            let paused = self.sessionLocked || self.displaySleeping
            self.orcaBridge.setPaused(paused)
            self.sceneWebViews.forEach { $0.setPaused(paused) }
        }
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "◉"
        statusItem?.button?.toolTip = "HALOFLUX"
        let menu = NSMenu()
        for (title, action) in [("Show Desktop Animation", #selector(showDesktop)), ("Preview Animation", #selector(showPreview)), ("About HALOFLUX", #selector(showAbout)), ("Quit HALOFLUX", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let speedMenu = NSMenu()
        let selected = UserDefaults.standard.object(forKey: "motionRate") as? Double ?? 0.25
        for (title, rate) in [("Slow · 25%", 0.25), ("Relaxed · 50%", 0.5), ("Original · 100%", 1.0)] {
            let item = NSMenuItem(title: title, action: #selector(changeSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = rate == selected ? .on : .off
            speedItems.append(item)
            speedMenu.addItem(item)
        }
        let speedRoot = NSMenuItem(title: "Animation Speed", action: nil, keyEquivalent: "")
        speedRoot.submenu = speedMenu
        menu.insertItem(speedRoot, at: 2)
        statusItem?.menu = menu
    }

    @objc private func changeSpeed(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(rate, forKey: "motionRate")
        speedItems.forEach { $0.state = $0 === sender ? .on : .off }
        for window in desktopWindows + (preview.map { [$0] } ?? []) {
            let views = [window.contentView].compactMap { $0 } + (window.contentView?.subviews ?? [])
            for case let web as WKWebView in views { web.evaluateJavaScript("window.haloMotionRate=\(rate);") }
        }
    }

    @objc private func showDesktop() {
        // macOS also sends screen-parameter notifications when switching Spaces.
        // Preserve the running scene unless display geometry actually changed.
        let layoutKey = NSScreen.screens.map {
            "\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0):\($0.frame):\($0.backingScaleFactor):\(topInset(for: $0))"
        }.joined(separator: "|")
        if layoutKey == desktopLayoutKey && !desktopWindows.isEmpty { return }
        desktopLayoutKey = layoutKey
        desktopWindows.forEach { $0.close() }
        desktopWindows.removeAll()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.title = "HALOFLUX Desktop"
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.backgroundColor = .black
            let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.black.cgColor
            // Keep the translucent menu bar and the camera notch over solid black.
            // Only reserve the top edge; visibleFrame also subtracts the Dock below.
            let topInset = topInset(for: screen)
            let web = HaloWebView(frame: NSRect(x: 0, y: 0, width: host.bounds.width,
                                               height: max(1, host.bounds.height - topInset)), liveAgents: true)
            web.onReady = { [weak self, weak web, weak window] in
                if let web, let window { self?.sceneReady(web, window: window) }
            }
            host.addSubview(web)
            window.contentView = host
            desktopWindows.append(window)
            window.orderFrontRegardless()
            web.loadAnimation(from: Bundle.main, page: "index.html")
        }
    }

    private func topInset(for screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    }

    private func previewWindow(_ title: String) -> NSWindow {
        preview?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1152, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.backgroundColor = .black
        window.center()
        preview = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    @objc private func showPreview() {
        let window = previewWindow("HALOFLUX · Animation Preview")
        let web = HaloWebView(frame: window.contentView!.bounds, liveAgents: true)
        web.onReady = { [weak self, weak web, weak window] in
            if let web, let window { self?.sceneReady(web, window: window) }
        }
        window.contentView = web
        web.loadAnimation(from: Bundle.main, page: "index.html")
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "HaloFlux for macOS · 0.1"
        alert.informativeText = "Modified from HALOFLUX by Ryder191 (RYDER CODE / Ms MAIKEBAIs CAT).\n\nOriginal work: github.com/Ryder191/haloflux\nmacOS adaptation: github.com/SHOCKY47/haloflux-mac\n\nPolyForm Noncommercial 1.0.0. Noncommercial use only. See the bundled LICENSE."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Original Project")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/Ryder191/haloflux") {
            NSWorkspace.shared.open(url)
        }
    }

    private func writeDiagnostic(_ record: [String: Any]) {
        guard let directory = diagnosticDirectory else { return }
        records.append(record)
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        }
    }

    private func diagnose(_ web: WKWebView, window: NSWindow) {
        guard let directory = diagnosticDirectory else { return }
        for (index, delay) in [3.0, 5.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                let js = """
                (() => {if(window.haloDebugState)return window.haloDebugState();const c = document.getElementById('stage');
                const p = c.getContext('2d').getImageData(0,0,c.width,c.height).data;
                let hash=2166136261, lit=0;
                for(let i=0;i<p.length;i+=64){hash=Math.imul(hash^p[i],16777619);if(p[i]>30)lit++;}
                return {time:typeof T==='number'?T:null, width:c.width,height:c.height,lit,hash:hash>>>0,
                visibility:document.visibilityState,paused:!!window.__wpPaused,errors:window.haloErrors||[],
                motionRate:motionRate(),dpr:DPR,webDensity:webBase.width/(2*R+4),targetDensity:detailDPR(),
                cameraZoom:cam.z,camZoom:C.camZoom,glow:C.glow};})()
                """
                web.evaluateJavaScript(js) { result, error in
                    var record = result as? [String: Any] ?? [:]
                    record["sample"] = index
                    record["windowNumber"] = window.windowNumber
                    record["windowLevel"] = window.level.rawValue
                    record["topInset"] = (window.contentView?.bounds.height ?? 0) - web.frame.maxY
                    record["bundlePath"] = Bundle.main.bundlePath
                    if let error { record["error"] = error.localizedDescription }
                    self?.writeDiagnostic(record)
                }
                web.takeSnapshot(with: nil) { picture, error in
                    if let tiff = picture?.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: directory.appendingPathComponent("frame-\(window.windowNumber)-\(index).png"))
                    }
                    if let error { self?.writeDiagnostic(["snapshotError": error.localizedDescription]) }
                }
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        orcaBridge.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
