import AppKit
import WebKit
import AVFoundation
import VideoToolbox
import CoreMedia

setbuf(stdout, nil)
let t0 = Date()
func log(_ s: String) { print(String(format: "[%6.2f] ", Date().timeIntervalSince(t0)) + s) }

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "help"

func windowDump(_ tag: String) {
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    log("windows \(tag):")
    var rows: [(Int, String)] = []
    for w in list {
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        guard layer < -2_000_000_000 || pid == me else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let on = (w[kCGWindowIsOnscreen as String] as? Int) ?? 0
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let name = w[kCGWindowName as String] as? String ?? ""
        let a = w[kCGWindowAlpha as String] as? Double ?? 1
        rows.append((layer, String(format: "  layer=%d %@ [%@] on=%d alpha=%.1f %.0fx%.0f @%.0f,%.0f%@", layer, owner, name, on, a, b["Width"] ?? 0, b["Height"] ?? 0, b["X"] ?? 0, b["Y"] ?? 0, pid == me ? "   <== PROBE" : "")))
    }
    for r in rows.sorted(by: { $0.0 < $1.0 }) { print(r.1) }
}

func codecs() {
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    let kinds: [(String, CMVideoCodecType)] = [("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC),
        ("ProRes 422", kCMVideoCodecType_AppleProRes422), ("AV1", kCMVideoCodecType_AV1), ("VP9", kCMVideoCodecType_VP9)]
    for (n, c) in kinds { print("\(n): hardware decode = \(VTIsHardwareDecodeSupported(c))") }
}

final class VideoDesktop {
    let window: NSWindow
    let layer = AVPlayerLayer()
    let player = AVQueuePlayer()
    var looper: AVPlayerLooper?
    init(url: URL, screen: NSScreen, level: Int, onTop: Bool = false) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.backgroundColor = .black
        window.isOpaque = true
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        layer.frame = v.bounds
        layer.videoGravity = .resizeAspectFill
        layer.preferredDynamicRange = .standard
        v.layer?.addSublayer(layer)
        window.contentView = v
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        item.preferredMaximumResolution = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        looper = AVPlayerLooper(player: player, templateItem: item)
        layer.player = player
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            guard let w = self?.window else { return }
            log("occlusion visible=\(w.occlusionState.contains(.visible)) raw=\(w.occlusionState.rawValue)")
        }
    }
    func show() { window.orderFrontRegardless(); player.play() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

switch mode {
case "codecs":
    codecs()
case "video":
    // probe video <path> <seconds> [level]
    let path = args[2]; let secs = Double(args[3]) ?? 30
    let level = args.count > 4 ? Int(args[4])! : Int(CGWindowLevelForKey(.desktopWindow))
    log("desktop window level \(CGWindowLevelForKey(.desktopWindow)), using \(level)")
    let d = VideoDesktop(url: URL(fileURLWithPath: path), screen: NSScreen.screens[0], level: level)
    d.show()
    log("shown; rate=\(d.player.rate)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { windowDump("after 2s"); log("status=\(d.player.status.rawValue) rate=\(d.player.rate) timeControl=\(d.player.timeControlStatus.rawValue)") }
    let ws = NSWorkspace.shared.notificationCenter
    for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
        ws.addObserver(forName: n, object: nil, queue: .main) { _ in log("EVENT \(n.rawValue)  rate=\(d.player.rate) tcs=\(d.player.timeControlStatus.rawValue) t=\(String(format: "%.1f", d.player.currentTime().seconds)) windowVisible=\(d.window.isVisible)") }
    }
    for n in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(n), object: nil, queue: .main) { _ in log("EVENT \(n)  rate=\(d.player.rate) tcs=\(d.player.timeControlStatus.rawValue) t=\(String(format: "%.1f", d.player.currentTime().seconds))") }
    }
    signal(SIGUSR1, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    sig.setEventHandler { if d.player.rate > 0 { d.player.pause(); log("PAUSED by signal") } else { d.player.play(); log("RESUMED by signal") } }
    sig.resume()
    var lastT = -1.0
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        let t = d.player.currentTime().seconds
        log(String(format: "beat t=%.1f advancing=%@ rate=%.1f tcs=%d vis=%@", t, t != lastT ? "yes" : "NO", d.player.rate, d.player.timeControlStatus.rawValue, d.window.occlusionState.contains(.visible) ? "Y" : "n"))
        lastT = t
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { log("done"); exit(0) }
    app.run()
case "web":
    // probe web <file-or-url> <seconds>
    let target = args[2]; let secs = Double(args[3]) ?? 60
    let screen = NSScreen.screens[0]
    let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    win.setFrame(screen.frame, display: false)
    win.isReleasedWhenClosed = false
    win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    win.ignoresMouseEvents = true; win.hasShadow = false; win.animationBehavior = .none; win.backgroundColor = .black; win.isOpaque = true
    let cfg = WKWebViewConfiguration()
    cfg.websiteDataStore = .nonPersistent()
    cfg.mediaTypesRequiringUserActionForPlayback = []
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
    let mute = WKUserScript(source: "(function(){function m(){document.querySelectorAll('video,audio').forEach(function(e){if(!e.__anodeSet){e.muted=true;e.__anodeSet=true}})};new MutationObserver(m).observe(document,{childList:true,subtree:true});setInterval(m,500);})()", injectionTime: .atDocumentStart, forMainFrameOnly: false)
    cfg.userContentController.addUserScript(mute)
    let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: cfg)
    web.setValue(false, forKey: "drawsBackground")
    let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    host.addSubview(web); win.contentView = host
    final class Nav: NSObject, WKNavigationDelegate {
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { log("didFinish \(w.url?.absoluteString ?? "")") }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { log("didFail \(e)") }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { log("didFailProvisional \(e)") }
    }
    let nav = Nav(); web.navigationDelegate = nav
    if target.hasPrefix("yt:") {
        let id = String(target.dropFirst(3))
        let html = "<!doctype html><meta charset=utf-8><body style='margin:0;background:#000'><iframe id=p style='position:fixed;inset:0;width:100vw;height:100vh;border:0' src='https://www.youtube.com/embed/\(id)?autoplay=1&mute=1&loop=1&playlist=\(id)&controls=0&playsinline=1&rel=0&origin=https://anode.app' allow='autoplay; encrypted-media'></iframe>"
        web.loadHTMLString(html, baseURL: URL(string: "https://anode.app/"))
    } else if target.hasPrefix("http") { web.load(URLRequest(url: URL(string: target)!)) }
    else { let u = URL(fileURLWithPath: target); web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
    win.orderFrontRegardless()
    var recipe = false, hidden = false
    signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
    let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    s1.setEventHandler {
        recipe.toggle()
        if recipe {   // the plan's recipe: suspend media + event + take the web view out of the window
            web.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m=>m.pause());window.dispatchEvent(new Event('anode-pause'))") { _, _ in
                web.removeFromSuperview(); log("RECIPE applied") }
        } else {
            host.addSubview(web)
            web.evaluateJavaScript("window.dispatchEvent(new Event('anode-resume'))", completionHandler: nil); log("RECIPE reversed")
        }
    }
    s1.resume()
    let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    s2.setEventHandler { hidden.toggle(); if hidden { win.orderOut(nil) } else { win.orderFrontRegardless() }; log("window hidden=\(hidden) (occlusion alone)") }
    s2.resume()
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        web.evaluateJavaScript("(function(){var v=document.querySelector('video');return v?('video paused='+v.paused+' muted='+v.muted+' t='+v.currentTime.toFixed(1)):'no video'})()") { r, _ in log("page: \(r ?? "?")") }
    }
    if let snap = ProcessInfo.processInfo.environment["SNAP"] {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            web.takeSnapshot(with: nil) { img, err in
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: snap)); log("snapshot saved") } else { log("snapshot failed \(String(describing: err))") }
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { log("done"); exit(0) }
    app.run()
case "tiles":
    // 4x3 tiny desktop windows; our own cover window moves over them. Run on an EMPTY desktop.
    let screen = NSScreen.screens[0]; let F = screen.frame
    let cols = 4, rows = 3, tw = F.width / CGFloat(cols), th = F.height / CGFloat(rows)
    var tiles: [NSWindow] = []
    func grid() -> String {
        (0..<rows).map { r in (0..<cols).map { c in tiles[r * cols + c].occlusionState.contains(.visible) ? "V" : "." }.joined(separator: " ") }.joined(separator: " / ")
    }
    for r in 0..<rows { for c in 0..<cols {
        // row 0 = top of the screen
        let frame = NSRect(x: F.minX + CGFloat(c) * tw, y: F.maxY - CGFloat(r + 1) * th, width: tw, height: th)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false); w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true; w.hasShadow = false; w.animationBehavior = .none
        w.backgroundColor = NSColor(hue: CGFloat(r * cols + c) / 12, saturation: 0.6, brightness: 0.5, alpha: 1); w.isOpaque = true
        w.orderFrontRegardless(); tiles.append(w)
    } }
    let cover = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    cover.isReleasedWhenClosed = false; cover.level = .normal; cover.backgroundColor = .white; cover.hasShadow = false
    cover.collectionBehavior = [.canJoinAllSpaces, .stationary]; cover.ignoresMouseEvents = true
    func place(_ name: String, _ r: NSRect?) {
        if let r { cover.setFrame(r, display: true); cover.orderFrontRegardless() } else { cover.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { log("\(name): \(grid())") }
    }
    log("initial (windows not yet reported): \(grid())")
    let top = F.maxY
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { log("empty desktop: \(grid())") }
    // 1) cover columns 0-1 entirely (left half, full height)
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { place("cover left half", NSRect(x: F.minX, y: F.minY, width: tw * 2, height: F.height)) }
    // 2) cover tile (row1,col1) except a 6 pt sliver on its right edge: sliver test
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { place("cover tile r1c1 except 6pt sliver", NSRect(x: F.minX + tw, y: top - 2 * th, width: tw - 6, height: th)) }
    // 3) cover tile r1c1 except 1pt
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { place("cover tile r1c1 except 1pt", NSRect(x: F.minX + tw, y: top - 2 * th, width: tw - 1, height: th)) }
    // 4) cover everything
    DispatchQueue.main.asyncAfter(deadline: .now() + 16) { place("cover whole screen", F) }
    // 5) uncover
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { place("uncovered", nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 24) { log("done"); exit(0) }
    app.run()
case "cuttiles":
    // probe cuttiles <clip> <outdir> <seconds> : 4x3 HEVC tile files of the first <seconds>
    let asset = AVURLAsset(url: URL(fileURLWithPath: args[2])); let out = URL(fileURLWithPath: args[3]); let secs = Double(args[4]) ?? 20
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let track = asset.tracks(withMediaType: .video)[0]
    let size = track.naturalSize; let cols = 4, rows = 3
    let tw = size.width / CGFloat(cols), th = size.height / CGFloat(rows)
    log("source \(size) -> tiles \(tw)x\(th)")
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: secs, preferredTimescale: 600))
    for r in 0..<rows { for c in 0..<cols {
        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: tw, height: th); comp.frameDuration = CMTime(value: 1, timescale: 30)
        let inst = AVMutableVideoCompositionInstruction(); inst.timeRange = range
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        li.setTransform(CGAffineTransform(translationX: -CGFloat(c) * tw, y: -CGFloat(r) * th), at: .zero)
        inst.layerInstructions = [li]; comp.instructions = [inst]
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else { log("no export session"); exit(1) }
        let url = out.appendingPathComponent("tile-\(r)-\(c).mov"); try? FileManager.default.removeItem(at: url)
        ex.outputURL = url; ex.outputFileType = .mov; ex.timeRange = range; ex.videoComposition = comp; ex.shouldOptimizeForNetworkUse = false
        let sem = DispatchSemaphore(value: 0); let t = Date()
        ex.exportAsynchronously { sem.signal() }; sem.wait()
        log("tile \(r),\(c): \(ex.status.rawValue) \(ex.error?.localizedDescription ?? "ok") \(String(format: "%.1f", Date().timeIntervalSince(t))) s \((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes")
    } }
case "tileplay":
    // probe tileplay <tiledir> <seconds> : 12 desktop windows, one looping player per tile
    let dir = URL(fileURLWithPath: args[2]); let secs = Double(args[3]) ?? 60
    let screen = NSScreen.screens[0]; let F = screen.frame
    let cols = 4, rows = 3, tw = F.width / CGFloat(cols), th = F.height / CGFloat(rows)
    var players: [AVQueuePlayer] = []; var loopers: [AVPlayerLooper] = []; var wins: [NSWindow] = []
    for r in 0..<rows { for c in 0..<cols {
        let frame = NSRect(x: F.minX + CGFloat(c) * tw, y: F.maxY - CGFloat(r + 1) * th, width: tw, height: th)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(frame, display: false); w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true; w.hasShadow = false; w.animationBehavior = .none; w.backgroundColor = .black; w.isOpaque = true
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size)); v.wantsLayer = true
        let l = AVPlayerLayer(); l.frame = v.bounds; l.videoGravity = .resizeAspectFill; v.layer?.addSublayer(l); w.contentView = v
        let p = AVQueuePlayer(); p.isMuted = true
        loopers.append(AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: dir.appendingPathComponent("tile-\(r)-\(c).mov"))))
        l.player = p; players.append(p); wins.append(w)
        w.orderFrontRegardless(); p.play()
    } }
    log("12 tiles playing")
    signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
    let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    s1.setEventHandler { for (i, p) in players.enumerated() where i >= 3 { p.pause() }; log("paused 9 of 12") }
    s1.resume()
    let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    s2.setEventHandler {
        // resume test: pause tile 0 for 10 s, resume with a zero-tolerance seek to the shared clock position
        let p = players[0]; let ref = players[1]
        p.pause(); log("tile 0 paused for 10 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let target = ref.currentTime(); let t0 = Date()
            p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { ok in
                let seekT = Date().timeIntervalSince(t0); p.play()
                // poll until the clock moves and status is playing
                func poll() { if p.timeControlStatus == .playing && p.currentTime() > target { log(String(format: "RESUME seek completed in %.0f ms (ok=%d); playing again after %.0f ms; |tile - ref| = %.0f ms", seekT * 1000, ok ? 1 : 0, Date().timeIntervalSince(t0) * 1000, abs(p.currentTime().seconds - ref.currentTime().seconds) * 1000)) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll) } }
                poll()
            }
        }
    }
    s2.resume()
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { log("done"); exit(0) }
    app.run()
default:
    print("modes: codecs | video <path> <seconds> [level]")
}
