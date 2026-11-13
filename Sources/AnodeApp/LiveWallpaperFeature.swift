import AppKit
import PowerKit
import UniformTypeIdentifiers

// ── Live Wallpapers (Beta Features) ─────────────────────────────────────────
//
// The section: switch it on, add videos, images, web pages and links to a library, choose what each display shows, and say what
// pauses it. The window is the controls and nothing else: the work is done by `LiveWallpaperController` (what is on screen),
// `WallpaperImporter` (getting content in) and `WallpaperPrefsStore` / `WallpaperLibrary` (what is kept). Every control writes
// its choice straight to the store; nothing here holds state of its own.
//
// While the feature is off only the checkbox shows.

/// How the section gets content into the library. The real one is `RealWallpaperImporter`; tests pass a fake.
protocol LiveWallpaperImporting: AnyObject {
    func addFile(_ url: URL) async throws -> ImportResult
    func addFolder(_ url: URL) async throws -> ImportResult
    func addLink(_ url: URL, downloadCopy: Bool, progress: @escaping (Double) -> Void) async throws -> ImportResult
    /// Stop a download in progress.
    func cancel()
}

final class RealWallpaperImporter: LiveWallpaperImporting {
    private let library: WallpaperLibrary
    private var downloader: WallpaperDownloader?

    init(library: WallpaperLibrary = .shared) { self.library = library }

    /// A file goes by its kind: a web page, an animated image (made into a video), a still image, otherwise a video.
    func addFile(_ url: URL) async throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            return try await WallpaperImporter.importHTMLFile(from: url, into: library, snapshot: WebWallpaperSurface.snapshot)
        }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            // A GIF (or animated PNG or WebP) with more than one frame becomes a looping video; a still one stays an image.
            if WallpaperImporter.animatedFrameCount(url) > 1 { return try await WallpaperImporter.importAnimatedImage(from: url, into: library) }
            return try await WallpaperImporter.importImage(from: url, into: library)
        }
        return try await WallpaperImporter.importVideo(from: url, into: library)
    }

    func addFolder(_ url: URL) async throws -> ImportResult {
        try await WallpaperImporter.importWebFolder(from: url, into: library, snapshot: WebWallpaperSurface.snapshot)
    }

    func addLink(_ url: URL, downloadCopy: Bool, progress: @escaping (Double) -> Void) async throws -> ImportResult {
        let d = WallpaperDownloader()
        downloader = d
        defer { downloader = nil }
        return try await WallpaperImporter.addLink(url, into: library, downloadCopy: downloadCopy, download: { source, dest, max in
            try await d.download(source, to: dest, maxBytes: max, progress: progress)
        }, snapshot: { page, size in
            // A YouTube link's preview is the video's thumbnail: a snapshot of the player would show its title and buttons.
            if let id = WallpaperURLClassifier.youtubeEmbedID(in: page), let image = await YouTubeStill.thumbnailImage(id: id) { return image }
            return try await WebWallpaperSurface.snapshot(page, size: size)
        })
    }

    func cancel() { downloader?.cancel() }
}

/// One library item in the list.
final class LibraryRowView: NSStackView {
    let item: WallpaperItem
    let detailLabel: NSTextField
    let removeButton: NSButton

    init(item: WallpaperItem, thumbnail: NSImage?, detail: String, detailColor: NSColor, target: AnyObject, remove: Selector) {
        self.item = item
        detailLabel = BetaFeaturesWindowController.wrapping(detail, color: detailColor)
        detailLabel.preferredMaxLayoutWidth = 250
        removeButton = NSButton(title: "Remove", target: target, action: remove)
        super.init(frame: .zero)
        let image = NSImageView(image: thumbnail ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 4
        image.layer?.masksToBounds = true
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 64), image.heightAnchor.constraint(equalToConstant: 40)])
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        let text = NSStackView(views: [name, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        addArrangedSubview(image)
        addArrangedSubview(text)
        addArrangedSubview(removeButton)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One connected display: what it shows, how that is going, and a way to try again.
final class DisplayRowView: NSStackView {
    let displayUUID: String
    let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let reloadButton: NSButton

    init(display: DisplayInfo, target: AnyObject, choose: Selector, reload: Selector) {
        displayUUID = display.uuid
        reloadButton = NSButton(title: "Reload", target: target, action: reload)
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: display.name)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.widthAnchor.constraint(equalToConstant: 120).isActive = true
        popUp.target = target
        popUp.action = choose
        popUp.controlSize = .small
        popUp.identifier = NSUserInterfaceItemIdentifier(display.uuid)
        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .small
        reloadButton.identifier = NSUserInterfaceItemIdentifier(display.uuid)
        let top = NSStackView(views: [name, popUp])
        top.orientation = .horizontal
        top.spacing = 8
        let bottom = NSStackView(views: [statusLabel, reloadButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        addArrangedSubview(top)
        addArrangedSubview(bottom)
        orientation = .vertical
        alignment = .leading
        spacing = 3
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

final class LiveWallpaperFeature: BetaFeature {

    let title = "Live Wallpapers"
    let summary = "Use a video, an image, a web page or a link to a video as your desktop wallpaper, on any display. It pauses "
                + "on battery, in Low Power Mode, when the Mac is hot, and when a full-screen app covers the desktop; it keeps "
                + "playing behind ordinary windows, maximized ones included. macOS still picks the menu bar's text colour from "
                + "your real wallpaper, so pick a dark wallpaper or use the menu bar backdrop."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let library: WallpaperLibrary
    private let prefsStore: WallpaperPrefsStore
    private let store: ShortcutStore
    private let displays: () -> [DisplayInfo]
    private let controller: () -> LiveWallpaperController?
    private let importer: LiveWallpaperImporting

    let enableCheckbox = NSButton(checkboxWithTitle: "Use live wallpapers", target: nil, action: nil)
    let bodyStack = NSStackView()
    let messageLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let addFileButton = NSButton(title: "Add file…", target: nil, action: nil)
    let addFolderButton = NSButton(title: "Add folder…", target: nil, action: nil)
    let addLinkButton = NSButton(title: "Add link…", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let libraryStack = NSStackView()
    let defaultPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let displaysStack = NSStackView()
    let scalingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let qualityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let speedSlider = NSSlider(value: 1, minValue: WallpaperPrefs.speedRange.lowerBound, maxValue: WallpaperPrefs.speedRange.upperBound,
                               target: nil, action: nil)
    let speedLabel = NSTextField(labelWithString: "")
    let muteCheckbox = NSButton(checkboxWithTitle: "Mute sound", target: nil, action: nil)
    let volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let batteryCheckbox = NSButton(checkboxWithTitle: "Pause on battery", target: nil, action: nil)
    let lowPowerCheckbox = NSButton(checkboxWithTitle: "Pause in Low Power Mode", target: nil, action: nil)
    let coveredCheckbox = NSButton(checkboxWithTitle: "Pause when a full-screen app covers the desktop", target: nil, action: nil)
    let hotCheckbox = NSButton(checkboxWithTitle: "Pause when the Mac is hot", target: nil, action: nil)
    let pauseButton = NSButton(title: "Pause wallpaper", target: nil, action: nil)
    let shortcutNote = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let customizeButton = NSButton(title: "Customize shortcut…", target: nil, action: nil)

    private var built = false
    private var busy = false
    private var signature = ""
    private var settingsToken: AnyObject?
    private var observers: [NSObjectProtocol] = []

    init(settings: Settings = .shared, library: WallpaperLibrary = .shared, prefsStore: WallpaperPrefsStore = .shared,
         store: ShortcutStore = .shared, displays: @escaping () -> [DisplayInfo] = { DisplayInfo.current() },
         controller: @escaping () -> LiveWallpaperController? = { LiveWallpaperController.current },
         importer: LiveWallpaperImporting? = nil) {
        self.settings = settings
        self.library = library
        self.prefsStore = prefsStore
        self.store = store
        self.displays = displays
        self.controller = controller
        self.importer = importer ?? RealWallpaperImporter(library: library)
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    // MARK: building

    var libraryRows: [LibraryRowView] { libraryStack.arrangedSubviews.compactMap { $0 as? LibraryRowView } }
    var displayRows: [DisplayRowView] { displaysStack.arrangedSubviews.compactMap { $0 as? DisplayRowView } }

    func makeView() -> NSView {
        enableCheckbox.target = self; enableCheckbox.action = #selector(enableToggled)
        for b in [addFileButton, addFolderButton, addLinkButton, cancelButton, pauseButton, customizeButton] {
            b.target = self; b.bezelStyle = .rounded; b.controlSize = .small
        }
        addFileButton.action = #selector(addFileClicked)
        addFolderButton.action = #selector(addFolderClicked)
        addLinkButton.action = #selector(addLinkClicked)
        cancelButton.action = #selector(cancelClicked)
        cancelButton.isHidden = true
        pauseButton.action = #selector(pauseClicked)
        customizeButton.action = #selector(customize)

        let adds = NSStackView(views: [addFileButton, addFolderButton, addLinkButton, cancelButton])
        adds.orientation = .horizontal
        adds.spacing = 8

        libraryStack.orientation = .vertical; libraryStack.alignment = .leading; libraryStack.spacing = 8
        displaysStack.orientation = .vertical; displaysStack.alignment = .leading; displaysStack.spacing = 8

        defaultPopUp.target = self; defaultPopUp.action = #selector(defaultChosen); defaultPopUp.controlSize = .small
        let defaultRow = NSStackView(views: [NSTextField(labelWithString: "Default for every display:"), defaultPopUp])
        defaultRow.orientation = .horizontal; defaultRow.spacing = 8

        scalingPopUp.target = self; scalingPopUp.action = #selector(scalingChosen); scalingPopUp.controlSize = .small
        for s in WallpaperScaling.allCases { scalingPopUp.addItem(withTitle: Self.title(for: s)) }
        let scalingRow = NSStackView(views: [NSTextField(labelWithString: "Picture:"), scalingPopUp])
        scalingRow.orientation = .horizontal; scalingRow.spacing = 8

        qualityPopUp.target = self; qualityPopUp.action = #selector(qualityChosen); qualityPopUp.controlSize = .small
        for q in YouTubeQuality.allCases { qualityPopUp.addItem(withTitle: q.title) }
        let qualityRow = NSStackView(views: [NSTextField(labelWithString: "YouTube quality:"), qualityPopUp])
        qualityRow.orientation = .horizontal; qualityRow.spacing = 8

        speedSlider.target = self; speedSlider.action = #selector(speedChanged); speedSlider.isContinuous = false
        speedSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        speedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let speedRow = NSStackView(views: [NSTextField(labelWithString: "Video speed:"), speedSlider, speedLabel])
        speedRow.orientation = .horizontal; speedRow.spacing = 8

        muteCheckbox.target = self; muteCheckbox.action = #selector(muteToggled)
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged); volumeSlider.isContinuous = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let soundRow = NSStackView(views: [muteCheckbox, NSTextField(labelWithString: "Volume:"), volumeSlider])
        soundRow.orientation = .horizontal; soundRow.spacing = 8

        for c in [batteryCheckbox, lowPowerCheckbox, coveredCheckbox, hotCheckbox] { c.target = self }
        batteryCheckbox.action = #selector(batteryToggled)
        lowPowerCheckbox.action = #selector(lowPowerToggled)
        coveredCheckbox.action = #selector(coveredToggled)
        hotCheckbox.action = #selector(hotToggled)
        let alwaysNote = BetaFeaturesWindowController.wrapping(
            "It always pauses while the display is asleep or the Mac is locked. A paused wallpaper keeps showing its last picture.",
            color: .secondaryLabelColor)

        let shortcutRow = NSStackView(views: [pauseButton, customizeButton])
        shortcutRow.orientation = .horizontal; shortcutRow.spacing = 8

        let heading: (String) -> NSTextField = { text in
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            return l
        }

        bodyStack.setViews([adds, messageLabel, libraryStack, heading("Displays"), defaultRow, displaysStack, heading("Playback"),
                            scalingRow, qualityRow, speedRow, soundRow, heading("Pause rules"), batteryCheckbox, lowPowerCheckbox, coveredCheckbox,
                            hotCheckbox, alwaysNote, shortcutRow, shortcutNote], in: .leading)
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 8

        let column = NSStackView(views: [enableCheckbox, bodyStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10

        built = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: WallpaperPrefsStore.didChange, object: prefsStore, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(nc.addObserver(forName: WallpaperLibrary.didChange, object: library, queue: .main) { [weak self] _ in self?.refresh() })
        settingsToken = settings.observe(Settings.Key.liveWallpaperEnabled) { [weak self] in self?.refresh() }
        controller()?.onChange = { [weak self] in self?.refresh() }
        refresh()
        return column
    }

    // MARK: refresh

    func refresh() {
        guard built else { return }
        let on = settings.liveWallpaperEnabled
        enableCheckbox.state = on ? .on : .off
        bodyStack.isHidden = !on
        controller()?.onChange = { [weak self] in self?.refresh() }
        guard on else { layoutChanged?(); return }

        let prefs = prefsStore.prefs
        let items = library.items
        let screens = displays()
        let c = controller()

        let sig = ([items.map { "\($0.id)|\($0.name)|\(library.isMissing($0))" }.joined(separator: ";"),
                    screens.map { "\($0.uuid)|\($0.name)|\(c?.status(forDisplay: $0.uuid) as Any)" }.joined(separator: ";"),
                    "\(prefs.assignments)"]).joined(separator: "#")
        if sig != signature {
            signature = sig
            rebuildLibrary(items)
            rebuildDefaultPopUp(items, prefs)
            rebuildDisplays(screens, items, prefs, c)
        }

        scalingPopUp.selectItem(at: WallpaperScaling.allCases.firstIndex(of: prefs.scaling) ?? 0)
        qualityPopUp.selectItem(at: YouTubeQuality.allCases.firstIndex(of: prefs.youtubeQuality) ?? 0)
        let assigned = screens.compactMap { prefs.assignments.resolved(forDisplay: $0.uuid) }.compactMap { library.item(id: $0) }
        let hasVideo = assigned.contains { $0.kind == .video }
        let hasSound = assigned.contains { $0.kind == .video || $0.kind == .web }
        speedSlider.doubleValue = prefs.speed
        speedSlider.isEnabled = hasVideo
        speedLabel.stringValue = String(format: "%.2f×", prefs.speed)
        speedLabel.textColor = hasVideo ? .labelColor : .tertiaryLabelColor
        muteCheckbox.state = prefs.muted ? .on : .off
        muteCheckbox.isEnabled = hasSound
        volumeSlider.doubleValue = Double(prefs.volume)
        volumeSlider.isEnabled = hasSound && !prefs.muted
        batteryCheckbox.state = prefs.pauseOnBattery ? .on : .off
        lowPowerCheckbox.state = prefs.pauseInLowPower ? .on : .off
        coveredCheckbox.state = prefs.pauseWhenCovered ? .on : .off
        hotCheckbox.state = prefs.pauseWhenHot ? .on : .off

        let paused = c?.userPaused ?? false
        pauseButton.title = paused ? "Resume wallpaper" : "Pause wallpaper"
        pauseButton.isEnabled = c != nil
        let key = (store.shortcut(for: ShortcutCommands.wallpaperPause) ?? ShortcutCommands.wallpaperPause.defaultShortcut).label
        shortcutNote.stringValue = "Pause or resume from anywhere with \(key) while this is on. You can change it in Customize."
        layoutChanged?()
    }

    private func rebuildLibrary(_ items: [WallpaperItem]) {
        for v in libraryStack.arrangedSubviews { libraryStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for item in items {
            let missing = library.isMissing(item)
            var detail = Self.detail(for: item)
            var color = NSColor.secondaryLabelColor
            if missing { detail = "File missing. Remove it, or add the file again."; color = .systemOrange }
            let thumb = library.thumbnailURL(item).flatMap { NSImage(contentsOf: $0) }
            libraryStack.addArrangedSubview(LibraryRowView(item: item, thumbnail: thumb, detail: detail, detailColor: color,
                                                           target: self, remove: #selector(removeClicked(_:))))
        }
    }

    private func rebuildDefaultPopUp(_ items: [WallpaperItem], _ prefs: WallpaperPrefs) {
        defaultPopUp.removeAllItems()
        defaultPopUp.addItem(withTitle: "None")
        for item in items { defaultPopUp.addItem(withTitle: item.name); defaultPopUp.lastItem?.representedObject = item.id }
        if let id = prefs.assignments.defaultItem, let i = items.firstIndex(where: { $0.id == id }) { defaultPopUp.selectItem(at: i + 1) }
        else { defaultPopUp.selectItem(at: 0) }
    }

    private func rebuildDisplays(_ screens: [DisplayInfo], _ items: [WallpaperItem], _ prefs: WallpaperPrefs, _ c: LiveWallpaperController?) {
        for v in displaysStack.arrangedSubviews { displaysStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for d in screens {
            let row = DisplayRowView(display: d, target: self, choose: #selector(displayChosen(_:)), reload: #selector(reloadClicked(_:)))
            row.popUp.addItem(withTitle: "Same as default")
            row.popUp.addItem(withTitle: "None")
            for item in items { row.popUp.addItem(withTitle: item.name); row.popUp.lastItem?.representedObject = item.id }
            switch prefs.assignments.perDisplay[d.uuid] {
            case nil, .inherit?: row.popUp.selectItem(at: 0)
            case .none?:         row.popUp.selectItem(at: 1)
            case .item(let id)?: row.popUp.selectItem(at: (items.firstIndex { $0.id == id }).map { $0 + 2 } ?? 0)
            }
            let status = c?.status(forDisplay: d.uuid) ?? .noWallpaper
            row.statusLabel.stringValue = Self.text(for: status)
            if case .failed = status { row.statusLabel.textColor = .systemOrange; row.reloadButton.isHidden = false }
            else { row.statusLabel.textColor = .secondaryLabelColor; row.reloadButton.isHidden = true }
            displaysStack.addArrangedSubview(row)
        }
    }

    // MARK: text

    static func title(for s: WallpaperScaling) -> String {
        switch s {
        case .fill:    return "Fill the screen"
        case .fit:     return "Fit inside the screen"
        case .stretch: return "Stretch to the screen"
        }
    }

    static func text(for status: WallpaperStatus) -> String {
        switch status {
        case .noWallpaper:                     return ""
        case .showing(let name):               return "Showing \(name)"
        case .playing(let name):               return "Playing \(name)"
        case .paused(let reason, let name):    return "Paused (\(text(for: reason))): \(name)"
        case .failed(let message):             return message
        }
    }

    static func text(for reason: WallpaperPauseReason) -> String {
        switch reason {
        case .userPaused:     return "paused by you"
        case .displaysAsleep: return "display asleep"
        case .screenLocked:   return "screen locked"
        case .ultraLowPower:  return "Ultra Low Power Mode"
        case .lowPowerMode:   return "Low Power Mode"
        case .onBattery:      return "on battery"
        case .tooHot:         return "the Mac is hot"
        case .covered:        return "desktop covered"
        }
    }

    static func detail(for item: WallpaperItem) -> String {
        var parts: [String] = []
        switch item.kind {
        case .video: parts.append("Video")
        case .image: parts.append("Image")
        case .web:   parts.append("Web page")
        }
        if let w = item.pixelWidth, let h = item.pixelHeight { parts.append("\(w)×\(h)") }
        if let d = item.durationSeconds { parts.append(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)) }
        if case .remote = item.source { parts.append(item.kind == .video ? "streamed" : "link") }
        var s = parts.joined(separator: " · ")
        if item.hardwareDecodable == false { s += "\nUses software decoding, which costs more battery." }
        return s
    }

    // MARK: adding

    private func setBusy(_ on: Bool, _ text: String? = nil) {
        busy = on
        for b in [addFileButton, addFolderButton, addLinkButton] { b.isEnabled = !on }
        cancelButton.isHidden = !on
        if let text { messageLabel.stringValue = text }
        layoutChanged?()
    }

    @MainActor
    private func run(_ busyText: String, _ work: () async throws -> ImportResult) async {
        guard !busy else { return }
        setBusy(true, busyText)
        do {
            let result = try await work()
            var message = "Added “\(result.item.name)”."
            if !result.warnings.isEmpty { message += " " + result.warnings.joined(separator: " ") }
            setBusy(false, message)
            // The first thing added is what the user wants to see, so it becomes the default if nothing is.
            var p = prefsStore.prefs
            if p.assignments.defaultItem == nil && library.items.count == 1 {
                p.assignments.defaultItem = result.item.id
                prefsStore.prefs = p
            }
        } catch is CancellationError {
            setBusy(false, "Cancelled.")
        } catch {
            setBusy(false, (error as? WallpaperImportError)?.message ?? error.localizedDescription)
        }
        refresh()
    }

    @MainActor
    func importFile(_ url: URL) async { await run("Adding \(url.lastPathComponent)…") { try await importer.addFile(url) } }
    @MainActor
    func importFolder(_ url: URL) async { await run("Adding \(url.lastPathComponent)…") { try await importer.addFolder(url) } }

    /// A link typed by the user. Refused here, with a message, if it isn't an https link; otherwise handed to the importer.
    @MainActor
    func submitLink(_ text: String, downloadCopy: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil || url.scheme == "file" else {
            messageLabel.stringValue = "That doesn't look like a web link."
            layoutChanged?()
            return
        }
        if case .unsupported(let why) = WallpaperURLClassifier.classify(url) {
            messageLabel.stringValue = why
            layoutChanged?()
            return
        }
        await run("Adding \(url.host ?? "link")…") {
            try await importer.addLink(url, downloadCopy: downloadCopy) { [weak self] fraction in
                DispatchQueue.main.async { self?.messageLabel.stringValue = "Downloading… \(Int(fraction * 100))%" }
            }
        }
    }

    func makeLinkPrompt() -> (view: NSView, field: NSTextField, downloadCheckbox: NSButton) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…"
        let check = NSButton(checkboxWithTitle: "Download a copy (recommended)", target: nil, action: nil)
        check.state = .on
        let note = BetaFeaturesWindowController.wrapping(
            "A copy keeps working offline and costs no network while it plays. Unticked, a video link is streamed every time.",
            color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = 360
        let stack = NSStackView(views: [field, check, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 100)
        return (stack, field, check)
    }

    @objc private func addFileClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .image, .html]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video, an image, or an HTML page."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in await self.importFile(url) }
    }

    @objc private func addFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a web wallpaper's folder. It needs an index.html at its top level."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in await self.importFolder(url) }
    }

    @objc private func addLinkClicked() {
        let prompt = makeLinkPrompt()
        let alert = NSAlert()
        alert.messageText = "Add a link"
        alert.informativeText = "A video, an image, a YouTube video, or a web page. Only https links work."
        alert.accessoryView = prompt.view
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = prompt.field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = prompt.field.stringValue, copy = prompt.downloadCheckbox.state == .on
        Task { @MainActor in await self.submitLink(text, downloadCopy: copy) }
    }

    @objc private func cancelClicked() { importer.cancel() }

    // MARK: removing and choosing

    func remove(_ id: UUID) {
        // Assignments first, so the surfaces close before their files go.
        var p = prefsStore.prefs
        p.assignments.removeItem(id)
        prefsStore.prefs = p
        do { try library.remove(id: id) } catch { messageLabel.stringValue = "Couldn't remove it: \(error.localizedDescription)" }
        refresh()
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw), let item = library.item(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(item.name)”?"
        alert.informativeText = "Its copy in the wallpaper library is deleted. The original file is not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { remove(id) }
    }

    @objc private func defaultChosen() {
        var p = prefsStore.prefs
        p.assignments.defaultItem = defaultPopUp.selectedItem?.representedObject as? UUID
        prefsStore.prefs = p
    }

    @objc private func displayChosen(_ sender: NSPopUpButton) {
        guard let uuid = sender.identifier?.rawValue else { return }
        var p = prefsStore.prefs
        switch sender.indexOfSelectedItem {
        case 0:  p.assignments.setChoice(.inherit, forDisplay: uuid)
        case 1:  p.assignments.setChoice(.none, forDisplay: uuid)
        default:
            if let id = sender.selectedItem?.representedObject as? UUID { p.assignments.setChoice(.item(id), forDisplay: uuid) }
        }
        prefsStore.prefs = p
    }

    @objc private func reloadClicked(_ sender: NSButton) {
        guard let uuid = sender.identifier?.rawValue else { return }
        controller()?.reload(displayUUID: uuid)
    }

    // MARK: preferences

    private func update(_ change: (inout WallpaperPrefs) -> Void) {
        var p = prefsStore.prefs
        change(&p)
        prefsStore.prefs = p
    }

    @objc private func enableToggled() { settings.liveWallpaperEnabled = enableCheckbox.state == .on }
    @objc private func scalingChosen() {
        let i = scalingPopUp.indexOfSelectedItem
        guard WallpaperScaling.allCases.indices.contains(i) else { return }
        update { $0.scaling = WallpaperScaling.allCases[i] }
    }
    @objc private func qualityChosen() {
        let i = qualityPopUp.indexOfSelectedItem
        guard YouTubeQuality.allCases.indices.contains(i) else { return }
        update { $0.youtubeQuality = YouTubeQuality.allCases[i] }
    }
    @objc private func speedChanged() { update { $0.speed = speedSlider.doubleValue } }
    @objc private func muteToggled() { update { $0.muted = muteCheckbox.state == .on } }
    @objc private func volumeChanged() { update { $0.volume = Float(volumeSlider.doubleValue) } }
    @objc private func batteryToggled() { update { $0.pauseOnBattery = batteryCheckbox.state == .on } }
    @objc private func lowPowerToggled() { update { $0.pauseInLowPower = lowPowerCheckbox.state == .on } }
    @objc private func coveredToggled() { update { $0.pauseWhenCovered = coveredCheckbox.state == .on } }
    @objc private func hotToggled() { update { $0.pauseWhenHot = hotCheckbox.state == .on } }

    @objc private func pauseClicked() {
        controller()?.toggleUserPaused()
        refresh()
    }
    @objc private func customize() { ShortcutsWindowController.shared.show() }
}
