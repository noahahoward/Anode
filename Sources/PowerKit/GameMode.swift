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
