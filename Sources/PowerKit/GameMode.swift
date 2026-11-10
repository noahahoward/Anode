import Foundation

// ── Game Mode HUD (Beta Features) ───────────────────────────────────────────
//
// A thin strip over a fullscreen game with temperatures, use, memory and battery. This file is the part that is arithmetic
// and nothing else: which corner, which app is a game, what the strip says and where it sits. No system calls, so all of
// it is tested without a window or a game. The controller and the window are in AnodeApp.

/// Which corner of the screen the strip sits in.
public enum HUDCorner: String, CaseIterable {
    case topRight, topLeft, bottomRight, bottomLeft
}

/// Apple's own Game Mode, as macOS announces it. The Darwin notification below carries a state: measured on 2026-11-09
/// (macOS 27) it read 1 with Bloons TD6 in front and 2 with a browser in front, and fired about 0.4 s after the switch. It is
/// not documented, so it is only ever ONE of the two ways a game is recognised (see `GameRules`).
public enum AppleGameMode {
    public static let notificationName = "com.apple.system.game_mode_status_changed"
    public static func isOn(state: UInt64) -> Bool { state == 1 }
}

public enum GameRules {

    /// A game is an app that says so: `LSApplicationCategoryType` is `public.app-category.games`, or one of the sub-categories
    /// (`simulation-games`, `action-games`, ...). Anything containing "games" counts.
    public static func isGameCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return category.lowercased().contains("games")
    }

    /// A game by its category, or because the owner added its bundle id by hand. The match on the id is exact.
    public static func isGame(bundleID: String?, category: String?, extraApps: [String]) -> Bool {
        if isGameCategory(category) { return true }
        guard let bundleID else { return false }
        return extraApps.contains(bundleID)
    }
}

// ── What the strip says ─────────────────────────────────────────────────────

public enum GameHUDText {

    /// The readings, in the order they are shown. Time-to-empty is not among them: it swings too much while a game runs.
    public static let metrics: [MetricID] = [.cpuTemperature, .cpuUsage, .gpuTemperature, .gpuUsage,
                                             .memoryUsage, .batteryPercent, .batteryDrain]

    private static let dash = "\u{2014}"
    private static let minus = "\u{2212}"

    /// `CPU 62° 41%   GPU 58° 77%   RAM 63%   BAT 84% −31 %/hr`, with a dash for any reading that is missing.
    public static func line(_ value: (MetricID) -> MetricValue?) -> String {
        func text(_ id: MetricID) -> String { value(id)?.text ?? dash }
        return "CPU \(text(.cpuTemperature)) \(text(.cpuUsage))   "
             + "GPU \(text(.gpuTemperature)) \(text(.gpuUsage))   "
             + "RAM \(text(.memoryUsage))   "
             + "BAT \(text(.batteryPercent)) \(drain(value(.batteryDrain)))"
    }

    /// The registry's drain reading is the size of the rate. A discharge is shown with a minus; a charge already carries its
    /// plus, and "AC" (label "Power") is the machine's own words for a Mac with nothing to report.
    private static func drain(_ v: MetricValue?) -> String {
        guard let v else { return dash }
        if v.text.hasPrefix("+") || v.label == "Power" { return v.text }
        return minus + v.text
    }
}

// ── Where the strip sits ────────────────────────────────────────────────────

public enum GameHUDPlacement {
    public static let height: CGFloat = 22
    public static let margin: CGFloat = 8
    /// The gap under a visible menu bar.
    static let menuBarGap: CGFloat = 4

    /// The strip's frame in Cocoa coordinates.
    ///
    /// Fullscreen on a notched screen the game is drawn under a black band (`safeTop` tall), and the strip sits inside it so it
    /// covers none of the game. Fullscreen on a screen with no notch it sits on the top edge. Windowed, the menu bar is visible
    /// and the strip goes just under it. The bottom corners ignore all of that.
    public static func frame(size: CGSize, corner: HUDCorner, screenFrame: CGRect, safeTop: CGFloat,
                             menuBarHeight: CGFloat, fullscreen: Bool) -> CGRect {
        let x: CGFloat
        switch corner {
        case .topRight, .bottomRight: x = screenFrame.maxX - margin - size.width
        case .topLeft, .bottomLeft: x = screenFrame.minX + margin
        }
        let y: CGFloat
        switch corner {
        case .bottomRight, .bottomLeft:
            y = screenFrame.minY + margin
        case .topRight, .topLeft:
            if !fullscreen {
                y = screenFrame.maxY - menuBarHeight - menuBarGap - size.height
            } else if safeTop > 0 {
                y = screenFrame.maxY - safeTop + (safeTop - size.height) / 2
            } else {
                y = screenFrame.maxY - size.height
            }
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
