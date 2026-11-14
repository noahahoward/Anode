import AppKit
import PowerKit

/// The first launch of a newly installed or updated Anode offers its helper at once (`HelperOfferRule`), through the same
/// install route the three sections' buttons use: one notice, then macOS's own password dialog.
///
/// Every part is given, so the order can be tested: nothing is asked while something else has the screen, the build is
/// remembered BEFORE the notice appears (a crash, a quit or a cancelled password cannot bring it back), and a helper that
/// is installed is asked what it speaks only when this build has not offered yet.
final class HelperOfferAtLaunch {
    private let thisBuild: String
    private let offeredForBuild: () -> String
    private let rememberOffered: (String) -> Void
    private let canInstall: () -> Bool
    private let isInstalled: () -> Bool
    /// Asks an installed helper what it speaks; nil when it did not answer.
    private let greet: (@escaping (Int?) -> Void) -> Void
    /// Nothing else has the screen: no first-run question is due, and Ultra Low Power Mode is off.
    private let mayAsk: () -> Bool
    private let start: (HelperOffer) -> Void

    init(thisBuild: String, offeredForBuild: @escaping () -> String, rememberOffered: @escaping (String) -> Void,
         canInstall: @escaping () -> Bool, isInstalled: @escaping () -> Bool,
         greet: @escaping (@escaping (Int?) -> Void) -> Void, mayAsk: @escaping () -> Bool,
         start: @escaping (HelperOffer) -> Void) {
        self.thisBuild = thisBuild
        self.offeredForBuild = offeredForBuild
        self.rememberOffered = rememberOffered
        self.canInstall = canInstall
        self.isInstalled = isInstalled
        self.greet = greet
        self.mayAsk = mayAsk
        self.start = start
    }

    /// Main thread.
    func run() {
        guard mayAsk() else { return }
        let installed = isInstalled()
        // Decided once without the helper: a build that has offered already, or cannot install, does not wake it.
        guard HelperOfferRule.offer(installed: false, helperVersion: nil, thisBuild: thisBuild,
                                    offeredForBuild: offeredForBuild(), canInstall: canInstall()) != nil else { return }
        guard installed else { return decide(installed: false, helperVersion: nil) }
        greet { [weak self] version in self?.decide(installed: true, helperVersion: version) }
    }

    private func decide(installed: Bool, helperVersion: Int?) {
        // Looked at again: the helper's answer can take a moment, and something may have taken the screen meanwhile.
        guard mayAsk(),
              let kind = HelperOfferRule.offer(installed: installed, helperVersion: helperVersion, thisBuild: thisBuild,
                                               offeredForBuild: offeredForBuild(), canInstall: canInstall()) else { return }
        rememberOffered(thisBuild)
        start(kind)
    }

    /// A moment after launch, so the window is up and the first-run question (if one is due) has been put up first.
    func runAfterLaunch(delay: TimeInterval = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.run() }
    }

    // ── The real one ────────────────────────────────────────────────────────

    /// Where the build the offer was last made for is kept. The app's own state, not a setting anyone chooses.
    static let offeredKey = "helper.offeredForBuild"

    /// `autoUpdateQuestionDue`: the first-run question about automatic updates has not been answered and this launch
    /// can show it (a sheet on the window). It goes first, and the offer follows its answer.
    static func live(panel: FanControlPanel, autoUpdateQuestionDue: @escaping () -> Bool,
                     connection: HelperConnection = .shared, defaults: UserDefaults = .standard) -> HelperOfferAtLaunch {
        let info = Bundle.main.infoDictionary
        let build = (info?["BSSourceCommit"] as? String) ?? (info?["CFBundleVersion"] as? String) ?? ""
        return HelperOfferAtLaunch(
            thisBuild: build,
            offeredForBuild: { defaults.string(forKey: offeredKey) ?? "" },
            rememberOffered: { defaults.set($0, forKey: offeredKey) },
            canInstall: { FanControlPanel.helperIsBundled },
            isInstalled: { FanDaemon.isInstalled() },
            greet: { done in
                // Its own claim on the shared connection, let go as soon as the helper has answered: an installed helper
                // is started by launchd to say what it speaks, and stops again when nobody holds it.
                connection.connect(for: .offer) { status in
                    connection.release(.offer)
                    if case .connected(_, let version) = status { done(version ?? 1) } else { done(nil) }
                }
            },
            mayAsk: {
                // The first-run question about automatic updates goes first, and nothing is asked over a mode that
                // has the Mac held down.
                !autoUpdateQuestionDue() && (UltraLowPowerController.current?.state ?? .off) == .off
            },
            start: { kind in
                NSApp.activate(ignoringOtherApps: true)
                panel.installHelper(report: { _ in }, from: kind == .install ? .afterInstall : .afterUpdate)
            })
    }
}
