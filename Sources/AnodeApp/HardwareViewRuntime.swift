import AppKit
import PowerKit

/// The real parts of Hardware View, for the app: what it reads of this Mac, the pane, and the fan panel that sends its slider
/// gestures. Nothing here runs until the tab is shown: the controller made here holds nothing until the pane appears, and every
/// reader below is called by the controller only while the tab is showing.
///
/// No timer, thread or observer of its own: the app's tick feeds the controller, and the one thread hop (the 24 h charge
/// history) is a single utility-queue read that the controller asks for at most once a minute.
enum HardwareViewRuntime {

    /// The hours of battery charge the view draws, and the most points it is given for them.
    static let chargeHistoryHours: Double = 24
    static let chargeHistoryMaxPoints = 96

    /// The most of the owner's menu bar widgets the picture of the menu bar carries: the picture has room for about this many
    /// beside the notch before they would run into the system items.
    static let maxMenuBarWidgets = 5

    /// - Parameters:
    ///   - configs: the owner's configured menu bar widgets (the widget controller's list).
    ///   - store: the history database, nil when the app has none.
    ///   - fanPanel: the Fans strip's control, which owns the one `FanSession` the view's sliders share.
    ///   - currentFans: the fans of the newest sensor reading (their limits travel with a slider gesture).
    ///   - makeHost: makes the pane, called once by the controller when the tab first appears; the app supplies one that keeps a
    ///     reference so it can install the view in the main window.
    static func live(settings: Settings = .shared,
                     configs: @escaping () -> [WidgetConfig],
                     store: @escaping () -> HistoryStore?,
                     fanPanel: FanControlPanel,
                     currentFans: @escaping () -> [FanInfo],
                     makeHost: @escaping () -> HardwarePane = { HardwarePane(frame: .zero) }) -> HardwareViewController {
        let providers = HardwareViewController.Providers(
            traits: { traits() },
            swapBytes: { swapUsedBytes() },
            // Only the built-in panel has a brightness of its own: an external main display must not dim the built-in picture.
            brightness: { CGDisplayIsBuiltin(CGMainDisplayID()) != 0 ? DisplayBrightness.current() : nil },
            // Cached for an hour inside `NVMeHealth`: asking is free, and nothing here polls the drive.
            nvme: { NVMeHealth.read() },
            volume: { bootVolume() },
            helperInstalled: { FanDaemon.isInstalled() },
            // The one session the Fans strip and the view's sliders share: its held fans are what reads MANUAL.
            heldFans: { [weak fanPanel] in fanPanel?.session.held ?? [:] },
            menuBarWidgets: {
                menuBarWidgets(configs: configs(), enabled: settings.menuBarWidgetsEnabled)
            },
            fetchChargeHistory: { done in
                fetchChargeHistory(store: store(), done: done)
            })
        return HardwareViewController(
            providers: providers,
            makeHost: { makeHost() as HardwareViewHosting },
            // The same gestures the Fans strip sends. The panel never installs the helper for a slider.
            sendFan: { [weak fanPanel] index, rpm in
                fanPanel?.hardwareViewFan(index: index, rpm: rpm, fans: currentFans())
            },
            // The same action as the Fans strip's own install button (its confirmation, then the system authorisation).
            installHelper: { [weak fanPanel] in
                fanPanel?.installHelper(report: { _ in }, from: .fansTab)
            })
    }

    // MARK: What the view reads

    /// What the Mac says about itself, for choosing the picture. Each trait is read, never looked up from a model table: a Mac
    /// whose battery, fans or built-in display cannot be read gets the generic picture.
    static func traits() -> MacTraits {
        MacTraits(model: Hardware.model,
                  chip: MachineInfo.facts.chip,
                  fans: FanPresence.onThisMac,
                  hasBattery: Battery.properties() != nil,
                  builtInDisplayPixelWidth: builtInDisplayPixelWidth())
    }

    /// IOKit's `kDisplayModeNativeFlag`: the mode is the panel's own resolution.
    private static let nativeModeFlag: UInt32 = 0x0200_0000

    /// The built-in display's NATIVE width in pixels, not the width of whichever scaled mode is in use (a "More Space" mode
    /// renders wider than the panel, and the layout rules match exact native widths). Among every mode the panel offers
    /// (duplicates of scaled modes included), the widest of those the system flags native; when none is flagged, the widest
    /// mode there is. nil when no built-in display is online (a desktop, or a laptop with the lid shut) or it lists no mode.
    static func builtInDisplayPixelWidth() -> Int? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success,
              let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(builtIn, options) as? [CGDisplayMode]) ?? []
        return nativePixelWidth(of: modes.map { (pixelWidth: $0.pixelWidth, ioFlags: $0.ioFlags) })
    }

    /// The rule above over plain values, so it is tested without a display.
    static func nativePixelWidth(of modes: [(pixelWidth: Int, ioFlags: UInt32)]) -> Int? {
        let native = modes.filter { $0.ioFlags & nativeModeFlag != 0 }.map { $0.pixelWidth }.max()
        return native ?? modes.map { $0.pixelWidth }.max()
    }

    /// `vm.swapusage` read directly, so a failed read is nil ("—" on the view) and never a 0 that claims no swap is in use.
    static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// Free and total space of the internal volume, from the Resources tab's own reading (held 30 s there). nil when no
    /// internal volume reports both.
    static func bootVolume() -> (freeBytes: UInt64, totalBytes: UInt64)? {
        guard let volume = StorageInfo.volumes().first(where: { $0.isInternal }),
              volume.totalBytes > 0, let free = volume.availableBytes, free >= 0 else { return nil }
        return (UInt64(free), UInt64(volume.totalBytes))
    }

    /// The owner's enabled widgets as the picture of the menu bar draws them: the label above the value for a labelled
    /// widget, the value alone otherwise. A metric with no reading yet shows "—". The group (Anode's own mark) is drawn by the
    /// picture itself, so it is not one of these. Nothing at all when the menu bar widgets are switched off.
    static func menuBarWidgets(configs: [WidgetConfig], enabled: Bool,
                               registry: MetricRegistry = .shared) -> [MenuBarWidgetText] {
        guard enabled else { return [] }
        let texts: [MenuBarWidgetText] = configs.compactMap { config in
            guard config.enabled, config.style != .group else { return nil }
            let id = MetricID(rawValue: config.metricID)
            let descriptor = registry.descriptor(for: id)
            let value = descriptor == nil ? nil : registry.value(for: id)
            let label = config.style == .textWithLabel ? (value?.label ?? descriptor?.shortTitle ?? "?") : nil
            return MenuBarWidgetText(label: label, value: value?.text ?? "\u{2014}")
        }
        return Array(texts.prefix(maxMenuBarWidgets))
    }

    /// Reads the last 24 hours of charge off the main thread and calls `done` on the main queue. With no database it never
    /// calls back, and the view has no history to draw.
    static func fetchChargeHistory(store: HistoryStore?, done: @escaping ([Double?]) -> Void) {
        guard let store else { return }
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let since = now.addingTimeInterval(-chargeHistoryHours * 3600)
            let points = store.powerSeries(since: since, until: now, maxPoints: chargeHistoryMaxPoints)
            let series = chargeSeries(from: points, since: since,
                                      width: chargeHistoryHours * 3600 / Double(chargeHistoryMaxPoints))
            DispatchQueue.main.async { done(series) }
        }
    }

    /// The 24 hours as `chargeHistoryMaxPoints` equal slots, oldest first, each `width` seconds wide from `since`. A slot no
    /// point falls in (the Mac was asleep or off, or no charge was recorded there) is nil: a break in the line, never 0, so
    /// the graph's x axis is real time rather than the rows that happen to exist. A point before `since` is skipped; a later
    /// point in the same slot overwrites an earlier one (a point with no charge never erases one that has it); a point past the end lands in the last slot.
    static func chargeSeries(from points: [HistoryStore.SeriesPoint], since: Date, width: TimeInterval) -> [Double?] {
        var slots = [Double?](repeating: nil, count: chargeHistoryMaxPoints)
        guard width > 0 else { return slots }
        for p in points where p.time >= since {
            // A point that recorded no charge leaves its slot as it is (a real reading already there is not erased).
            guard let soc = p.socPercent else { continue }
            let slot = Int((p.time.timeIntervalSince(since) / width).rounded(.down))
            slots[min(max(slot, 0), chargeHistoryMaxPoints - 1)] = soc
        }
        return slots
    }
}
