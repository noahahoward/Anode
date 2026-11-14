import Foundation

/// What a newly installed or updated Anode offers to do about its helper, on its first launch.
public enum HelperOffer: Equatable {
    /// No helper is installed.
    case install
    /// The helper installed speaks less than this app: something this build can do needs a newer one.
    case update
}

/// Whether to offer, decided from plain facts so every case can be tested.
///
/// The helper was only ever installed from a button in the Fans tab, Charge Control or Ultra Low Power Mode, which a person
/// had to find. The owner asked for it to be offered at once when Anode is installed or updated instead.
public enum HelperOfferRule {
    /// What to offer on this launch, or nil.
    ///
    /// - `helperVersion` is what an installed helper said it speaks, nil when none answered. "Older" is judged by that and
    ///   never by the file: the helper's binary differs in every build, and an update that changes nothing the helper
    ///   speaks must not ask for a password.
    /// - `thisBuild` names the running build; `offeredForBuild` is the build the offer was last made for. "Not Now", a
    ///   cancelled password and a failed install are all answers, so one build asks once.
    public static func offer(installed: Bool, helperVersion: Int?, appVersion: Int = FanDaemon.protocolVersion,
                             thisBuild: String, offeredForBuild: String, canInstall: Bool) -> HelperOffer? {
        guard canInstall, !thisBuild.isEmpty, offeredForBuild != thisBuild else { return nil }
        guard installed else { return .install }
        // Installed and silent says nothing about what it speaks: a password is not asked for on a guess.
        guard let helperVersion else { return nil }
        return helperVersion < appVersion ? .update : nil
    }
}

/// The words of the notice, here so a test holds them to the helper's whole vocabulary.
public enum HelperOfferNotice {
    public static func title(_ kind: HelperOffer) -> String {
        kind == .install ? "Install the Anode helper?" : "Update the Anode helper?"
    }

    public static func button(_ kind: HelperOffer) -> String { kind == .install ? "Install" : "Update" }

    public static let notNow = "Not Now"

    public static func text(_ kind: HelperOffer) -> String {
        let why = kind == .install ? "Anode was just installed." : "Anode was just updated, and its helper is an older one."
        return why + " " + HelperVocabulary.whatItIsFor + "\n\n"
            + "It runs as root, only while Anode needs it, and it can: " + HelperVocabulary.sentence + ".\n\n"
            + "macOS will ask for your password. "
            + "You can also do this later from the Fans tab, Charge Control or Ultra Low Power Mode."
    }

    /// What the app says once it is done.
    public static func finished(_ kind: HelperOffer) -> String {
        (kind == .install ? "The Anode helper is installed. " : "The Anode helper is up to date. ")
            + HelperVocabulary.whatItIsFor
    }
}
