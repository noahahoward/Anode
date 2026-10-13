import AppKit
import PowerKit

/// Checks for an update once per launch, and runs it.
///
/// Once, because the check is a round trip to GitHub that the window waits on,
/// and the window is opened from a widget many times a day. Quitting and
/// reopening Anode is what asks again. The check is made when the window first
/// opens rather than at launch itself, so a launch at login into the menu bar
/// does not put an update panel on screen with nobody there.
///
/// `AutoUpdate` in PowerKit holds the rules; this is the part that touches
/// git, the script and the screen. Main thread only, apart from the two blocks
/// that say otherwise.
final class AutoUpdater {

    static let shared = AutoUpdater()

    private let settings = Settings.shared
    private var checked = false
    private var checking = false
    private var panel: UpdatePanelController?
    private var tail: Timer?

    /// The log of the last automatic update, kept so a failure can be read.
    static var logURL: URL { UpdateLauncher.wrapperURL(named: "update.log") }

    private var checkoutPath: String? {
        guard UpdateLauncher.bundledScript() != nil else { return nil }
        return SourceCheckout.recordedPath(in: .main)
    }

    /// Whether this build can update itself at all — it needs a recorded
    /// checkout and the bundled script. Preferences greys the checkbox without.
    var isAvailable: Bool { checkoutPath != nil }

    /// Run `open` when the window should appear, which is straight away unless
    /// this is the first open since launch, the setting is on and the checkout
    /// turns out to be behind. In that case
    /// the update panel is shown instead and `open` is only called if the
    /// update fails.
    func gate(_ open: @escaping () -> Void) {
        // Mid-update, every way of opening the window leads to the panel.
        if let panel { return panel.show() }
        guard !checked, settings.autoUpdateEnabled, let path = checkoutPath,
              AutoUpdate.mayCheckUnasked(path: path,
                                         confirmedPath: settings.autoUpdateConfirmedPath)
        else { return open() }
        // A second click while the first is still waiting: that one will open.
        guard !checking else { return }
        checking = true
        checked = true

        // Whichever of the answer and the timeout arrives first decides; the
        // other finds `settled` set and does nothing. A late answer is not
        // acted on — the window is up by then — and the next launch asks again.
        var settled = false
        let settle: (Finding?) -> Void = { [weak self] finding in
            guard let self, !settled else { return }
            settled = true
            self.checking = false
            guard let finding,
                  AutoUpdate.decision(enabled: self.settings.autoUpdateEnabled,
                                      state: finding.state,
                                      upstreamCommit: finding.commit,
                                      failedCommit: self.settings.autoUpdateFailedCommit)
                    == .update
            else { return open() }
            self.update(checkout: path, to: finding, otherwise: open)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let checkout = SourceCheckout.atPath(path)
            checkout.fetch()
            let finding = Finding(state: checkout.state(),
                                  commit: checkout.upstreamCommit(),
                                  build: checkout.upstreamBuild())
            DispatchQueue.main.async { settle(finding) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoUpdate.checkTimeout) { settle(nil) }
    }

    /// Record that git could read the checkout while a window was up, so later
    /// checks may run with none. Called with the answer to any check the user
    /// asked for.
    func noteAsked(_ state: SourceCheckout.State) {
        guard AutoUpdate.confirmsAccess(state),
              let path = SourceCheckout.recordedPath(in: .main) else { return }
        settings.autoUpdateConfirmedPath = path
    }

    /// Read the checkout once, now, on the user's say-so. This is where a
    /// consent prompt for a checkout under Downloads is meant to appear: with a
    /// window on screen to host it.
    func confirmAccess() {
        guard let path = checkoutPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let state = SourceCheckout.atPath(path).state()
            DispatchQueue.main.async { self.noteAsked(state) }
        }
    }

    // ── Updating ────────────────────────────────────────────────────────────

    private struct Finding {
        let state: SourceCheckout.State
        let commit: String?
        let build: Int?
    }

    /// Runs the bundled `update.sh` with its output in a log file.
    ///
    /// A file and not a pipe, because the script outlives this process:
    /// `build-app.sh` quits the running app before installing the new one, and
    /// a script writing to a pipe whose reader has gone is killed by the write.
    private func update(checkout path: String, to finding: Finding,
                        otherwise open: @escaping () -> Void) {
        guard let script = UpdateLauncher.bundledScript() else { return open() }
        let log = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard fm.createFile(atPath: log.path, contents: nil),
              let output = try? FileHandle(forWritingTo: log),
              let reader = try? FileHandle(forReadingFrom: log) else { return open() }

        let panel = UpdatePanelController(build: finding.build)
        panel.onDismiss = { [weak self] in
            self?.panel = nil
            open()
        }
        self.panel = panel
        panel.show()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.finished(status: status, commit: finding.commit) }
        }
        do { try process.run() } catch {
            return fail("The updater could not be started: \(error.localizedDescription)",
                        commit: finding.commit)
        }

        var progress = AutoUpdate.Progress()
        var partial = Data()
        var quitting = false
        tail = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            partial.append(reader.availableData)
            while let newline = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
                partial.removeSubrange(partial.startIndex...newline)
                progress.consume(line: line)
            }
            self?.panel?.update(progress)
            // The new bundle is in place. `build-app.sh` has already asked this
            // process to quit; if that did not land, the relaunch that follows
            // would only bring this old copy forward, so go now.
            if progress.stage >= .installing, !quitting {
                quitting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }

    private func finished(status: Int32, commit: String?) {
        guard panel != nil, tail != nil else { return }
        if status == 0 {
            // Finished without replacing this process — nothing to wait for.
            stopTailing()
            panel?.close()
        } else {
            fail("The update did not finish, and Anode is still the build it was. It "
                 + "will not be tried again until there is a newer commit; ./update.sh "
                 + "in your checkout runs it by hand.", commit: commit)
        }
    }

    private func fail(_ reason: String, commit: String?) {
        stopTailing()
        settings.autoUpdateFailedCommit = commit
        panel?.fail(reason, log: Self.logURL)
    }

    private func stopTailing() {
        tail?.invalidate()
        tail = nil
    }
}
