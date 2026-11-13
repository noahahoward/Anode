import AppKit
import PowerKit

// ── Ultra Low Power Mode: the confirm box ───────────────────────────────────
//
// A small panel that says what will be kept and lists, by name, what will be frozen. Nothing has changed yet when it is up.
//
// It must not take the front app's place. The panel is a non-activating one, ordered front without Anode becoming the active
// app (`orderFrontRegardless`, never `NSApp.activate`), so the app the owner was using stays the front app and the box can
// appear over a full-screen one. It does become the key window, and that is deliberate: Escape cannot cancel a box that can
// never receive a key. Return does NOT confirm: the box can come up while the owner is typing, and a stray Return would freeze
// their Mac.

/// The one answer a box is owed. Whatever closes the box (Confirm, Cancel, the close button, the system, a second question)
/// goes through here, so the controller hears exactly one answer to each question.
final class UltraPendingAnswer {

    private var answer: ((Bool) -> Void)?

    var isPending: Bool { answer != nil }

    /// A new question. The one still pending is answered No, after this one is in place: whatever that answer does (it may
    /// ask again) finds the box already holding the new question.
    func replace(_ new: @escaping (Bool) -> Void) {
        let old = answer
        answer = new
        old?(false)
    }

    /// The answer to the pending question. Nothing happens when there is none: it was answered already.
    func give(_ yes: Bool) {
        guard let current = answer else { return }
        answer = nil
        current(yes)
    }
}

final class UltraConfirmPanel: NSObject, UltraConfirming, NSWindowDelegate {

    static let title = "Ultra Low Power Mode"
    /// What the box says about the screen and Low Power Mode, under the headline.
    static let screenLine = "The screen is held at half brightness or lower, and Low Power Mode is switched on if Anode's helper "
        + "is installed."

    /// Put the panel on screen, and take it off. The tests replace them: a panel built and never shown is not on screen.
    var present: (NSPanel) -> Void = { $0.orderFrontRegardless(); $0.makeKey() }
    var dismiss: (NSPanel) -> Void = { $0.orderOut(nil) }
    static let width: CGFloat = 420
    private static let inset: CGFloat = 20

    private let pending = UltraPendingAnswer()
    private(set) var panel: NSPanel?
    let headline = NSTextField(wrappingLabelWithString: "")
    let screenLabel = NSTextField(wrappingLabelWithString: UltraConfirmPanel.screenLine)
    private let caption = NSTextField(labelWithString: "Will be frozen:")
    private let list = NSTextView.scrollableTextView()
    private var listHeight: NSLayoutConstraint?
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let confirmButton = NSButton(title: "Confirm", target: nil, action: nil)
    private var content: NSStackView?

    // ── Asking ──────────────────────────────────────────────────────────────

    func ask(kept: [String], frozen: [String], answer: @escaping (Bool) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in ask(kept: kept, frozen: frozen, answer: answer) }
            return
        }
        // A box already up is answered No, and this question takes its place on the same panel.
        pending.replace(answer)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        fill(kept: kept, frozen: frozen)
        let size = content?.fittingSize ?? NSSize(width: Self.width, height: 200)
        panel.setContentSize(size)
        let area = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(Self.centred(panel.frame.size, in: area), display: false)
        present(panel)
    }

    /// Where a box of `size` sits: in the middle of `area` (the visible part of the screen that carries the menu bar). One
    /// larger than the area keeps its top-left corner on it.
    static func centred(_ size: NSSize, in area: NSRect) -> NSRect {
        let x = size.width >= area.width ? area.minX : area.midX - size.width / 2
        let y = size.height >= area.height ? area.maxY - size.height : area.midY - size.height / 2
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func fill(kept: [String], frozen: [String]) {
        headline.stringValue = UltraMenu.confirmText(kept: kept, frozenCount: frozen.count)
        (list.documentView as? NSTextView)?.string = frozen.joined(separator: "\n")
        // The list is only shown when there is something in it, and no taller than a screenful of rows.
        caption.isHidden = frozen.isEmpty
        list.isHidden = frozen.isEmpty
        listHeight?.constant = min(150, max(48, CGFloat(frozen.count) * 15 + 12))
        content?.layoutSubtreeIfNeeded()
    }

    // ── Answering ───────────────────────────────────────────────────────────

    @objc private func confirmPressed() { finish(true) }
    @objc private func cancelPressed() { finish(false) }

    /// The box goes first, then the answer is given. An answer may ask again (a second question takes this same panel and
    /// shows it): if the box were put away after the answer, it would hide that new question, and nothing would be left on
    /// screen to answer it. (`orderOut` does not post `windowWillClose`, so putting it away first cannot answer anything.)
    private func finish(_ yes: Bool) {
        if let panel { dismiss(panel) }
        pending.give(yes)
    }

    /// The names the box lists as to be frozen.
    var listedNames: [String] {
        ((list.documentView as? NSTextView)?.string ?? "").split(separator: "\n").map(String.init)
    }

    /// The close button: a No, and the box is put away the way Cancel puts it away rather than closed, so that an answer which
    /// asks again finds the panel still there to show.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(false)
        return false
    }

    /// The system closing the window by some other route: that is a No too.
    func windowWillClose(_ notification: Notification) { pending.give(false) }

    // ── The panel ───────────────────────────────────────────────────────────

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = Self.title
        // A panel hides when its app is not the active one, and this app never is while the box is up.
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.delegate = self

        let textWidth = Self.width - 2 * Self.inset
        headline.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        headline.preferredMaxLayoutWidth = textWidth
        screenLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        screenLabel.textColor = .secondaryLabelColor
        screenLabel.preferredMaxLayoutWidth = textWidth
        caption.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        let height = list.heightAnchor.constraint(equalToConstant: 100)
        height.isActive = true
        listHeight = height
        if let text = list.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = false
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textContainerInset = NSSize(width: 4, height: 4)
        }

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed)
        for button in [cancelButton, confirmButton] { button.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        let stack = NSStackView(views: [headline, screenLabel, caption, list, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        p.contentView = stack
        content = stack
        return p
    }
}
