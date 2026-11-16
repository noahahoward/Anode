import Foundation

/// An output Core Audio lists: its stable id (the device UID), what it is called, and what kind of thing it is.
public struct OutputDevice: Equatable {
    public var id: String
    public var name: String
    public var kind: OutputKind
    public init(id: String, name: String, kind: OutputKind) { self.id = id; self.name = name; self.kind = kind }
}

/// What the Sound menu shows, in one value: Anode's own readings (volume, outputs, batteries) joined with what macOS's own
/// panel said last (the listening mode and the AirPlay speakers). A menu is drawn from this and nothing else.
public struct SoundMenuModel: Equatable {

    public struct Battery: Equatable {
        public var left: Int?, right: Int?, case_: Int?
        public var leftCharging = false, rightCharging = false, caseCharging = false
        public init(left: Int? = nil, right: Int? = nil, case_: Int? = nil) { self.left = left; self.right = right; self.case_ = case_ }
    }

    public struct Device: Equatable {
        /// The Core Audio id; nil for an AirPlay speaker, which only macOS's panel knows about.
        public var id: String?
        public var name: String
        public var kind: OutputKind
        public var isSelected: Bool
        public var battery: Battery?
        public init(id: String?, name: String, kind: OutputKind, isSelected: Bool, battery: Battery? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.isSelected = isSelected; self.battery = battery
        }
    }

    public var volume: Double
    public var muted: Bool
    public var devices: [Device]
    /// The device whose section is open (listening mode and the rest shown), if any.
    public var expandedDevice: String?
    public var listening: [AppleChoiceRow]
    public var spatial: [AppleChoiceRow]
    public var conversation: [AppleChoiceRow]
    /// Whether macOS's panel could be read: without it the rows only it can drive are missing or disabled.
    public var appleAvailable: Bool
    /// One line under the rows when something needs saying (a refusal, a missing permission).
    public var notice: String?

    public init(volume: Double, muted: Bool, devices: [Device], expandedDevice: String?, listening: [AppleChoiceRow],
                spatial: [AppleChoiceRow], conversation: [AppleChoiceRow], appleAvailable: Bool, notice: String? = nil) {
        self.volume = volume; self.muted = muted; self.devices = devices; self.expandedDevice = expandedDevice
        self.listening = listening; self.spatial = spatial; self.conversation = conversation
        self.appleAvailable = appleAvailable; self.notice = notice
    }

    /// Joins the two sources. When macOS's panel was read, its order wins (that is the order people know) and the speakers only
    /// it lists are included; without it, Core Audio's outputs alone, the built-in one first.
    public static func merge(outputs: [OutputDevice], defaultID: String?, volume: Double, muted: Bool,
                             batteries: [AccessoryBattery], apple: AppleSoundPanel?, expanded: String? = nil) -> SoundMenuModel {
        func battery(for kind: OutputKind) -> Battery? {
            guard kind == .airpods || kind == .airpodsPro,
                  let group = batteries.first?.group else { return nil }
            let mine = batteries.filter { $0.group == group }
            var b = Battery()
            for x in mine {
                switch x.part {
                case .left: b.left = x.percent; b.leftCharging = x.charging
                case .right: b.right = x.percent; b.rightCharging = x.charging
                case .case_: b.case_ = x.percent; b.caseCharging = x.charging
                case .single: b.left = x.percent; b.leftCharging = x.charging
                }
            }
            return b
        }
        func device(_ o: OutputDevice) -> Device {
            Device(id: o.id, name: o.name, kind: o.kind, isSelected: o.id == defaultID, battery: battery(for: o.kind))
        }
        let local = outputs.sorted { ($0.kind == .speakers ? 0 : 1) < ($1.kind == .speakers ? 0 : 1) }
        var devices: [Device]
        if let apple, !apple.devices.isEmpty {
            devices = apple.devices.map { row in
                if let o = outputs.first(where: { $0.name == row.name }) { return device(o) }
                return Device(id: nil, name: row.name, kind: OutputKind.guess(name: row.name, transport: "airp"), isSelected: row.isSelected)
            }
            // An output Core Audio has that macOS's panel did not list still shows, at the end.
            devices += local.filter { o in !devices.contains { $0.name == o.name } }.map(device)
        } else {
            devices = local.map(device)
        }
        let open = expanded ?? apple?.expandedDevice
        let show = open != nil && devices.contains { $0.name == open }
        return SoundMenuModel(volume: volume, muted: muted, devices: devices, expandedDevice: show ? open : nil,
                              listening: show ? apple?.listening ?? [] : [], spatial: show ? apple?.spatial ?? [] : [],
                              conversation: show ? apple?.conversation ?? [] : [], appleAvailable: apple != nil)
    }
}

extension SoundMenuModel {
    /// The buttons at the bottom: the selected AirPods' own settings (macOS shows these only for them), then Sound Settings.
    public var footerTitles: [String] {
        var titles: [String] = []
        if let d = devices.first(where: { $0.isSelected && ($0.kind == .airpods || $0.kind == .airpodsPro) }) {
            titles.append("\(d.name) Settings…")
        }
        titles.append("Sound Settings…")
        return titles
    }
}
