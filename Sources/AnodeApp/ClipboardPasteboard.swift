import AppKit
import Carbon.HIToolbox
import PowerKit

// ── The real pasteboard, and the paste ──────────────────────────────────────
//
// The only code of Clipboard History that touches `NSPasteboard.general` or posts a key. Everything else works on values
// (`ClipboardSnapshot`, `ClipboardEntry`) or on the closures these are passed in as, so the rest is tested without the person's
// clipboard.

enum RealClipboard {

    /// The pasteboard's change counter. Reading it reads none of what is copied.
    static var changeCount: Int { NSPasteboard.general.changeCount }

    /// The type strings now on the pasteboard.
    static func types() -> [String] { (NSPasteboard.general.types ?? []).map(\.rawValue) }

    /// How macOS lets this app read the pasteboard (macOS 15.4 and later can ask the person first), for the log.
    static func accessDescription() -> String {
        guard #available(macOS 15.4, *) else { return "always (this macOS does not ask)" }
        switch NSPasteboard.general.accessBehavior {
        case .default: return "default"
        case .ask: return "ask"
        case .alwaysAllow: return "always allowed"
        case .alwaysDeny: return "denied"
        @unknown default: return "unknown"
        }
    }

    /// The forms an entry is kept in (`ClipboardTypes.essential`: text, links, files, pictures, rich text) of the first few items,
    /// and no others: an app's own private formats are never read, and a copy of a thousand things is not held. The entry cap is
    /// `maxBytes`; reading goes on to twice that so that an entry a little over it can still be kept in fewer forms, and gives up
    /// beyond (nil). The one form being read when that happens has been read whole (the pasteboard cannot say how big a form is
    /// before it is read), so the most this holds at once is the cap's double and the largest single form.
    static let maxItems = 32
    static func read(maxBytes: Int) -> [ClipboardRepresentation]? {
        guard let items = NSPasteboard.general.pasteboardItems else { return nil }
        var out: [ClipboardRepresentation] = []
        var total = 0
        for (index, item) in items.prefix(maxItems).enumerated() {
            // Words and links first, pictures last: a big picture is the only form that can be large.
            let kept = item.types.filter { ClipboardTypes.essential.contains($0.rawValue) }
            let wanted = kept.filter { !ClipboardTypes.images.contains($0.rawValue) } + kept.filter { ClipboardTypes.images.contains($0.rawValue) }
            for type in wanted {
                guard total <= maxBytes * 2, let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maxBytes * 2 { return nil }
                out.append(ClipboardRepresentation(item: index, type: type.rawValue, data: data))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Puts an entry back on the pasteboard, as it was copied. With `plainTextOnly` and a plain text form among them, only
    /// that. Returns the change counter after the write, so the watcher knows the change is Anode's own.
    static func write(_ reps: [ClipboardRepresentation], plainTextOnly: Bool) -> Int {
        var reps = reps
        if plainTextOnly, let plain = reps.first(where: { ClipboardTypes.plainText.contains($0.type) }) {
            reps = [ClipboardRepresentation(item: 0, type: "public.utf8-plain-text", data: plain.data)]
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let byItem = Dictionary(grouping: reps, by: \.item)
        var items: [NSPasteboardItem] = []
        for index in byItem.keys.sorted() {
            let item = NSPasteboardItem()
            for rep in byItem[index] ?? [] { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
            items.append(item)
        }
        pb.writeObjects(items)
        return pb.changeCount
    }
}

/// Sends ⌘V to whatever app is in front.
enum PasteKeystroke {

    /// The key that types `character` on the keyboard layout in use (⌘V is where V is, not always where it is on a US
    /// keyboard: Dvorak and others differ), found by asking the layout, and `fallback` when it cannot be asked.
    static func keyCode(typing character: Character, fallback: CGKeyCode) -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let wanted = String(character).lowercased()
        for code in 0..<128 {
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == wanted {
                return CGKeyCode(code)
            }
        }
        return fallback
    }

    /// ⌘V as a press and a release, with ⌘ the only modifier: a Globe key still held when it is sent does not go with it.
    /// False without Accessibility, which macOS requires to post a key.
    static func paste() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let key = keyCode(typing: "v", fallback: CGKeyCode(kVK_ANSI_V))
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = .maskCommand
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }
}
