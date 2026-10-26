import Foundation

/// A1 (owner, 2026-10-25): a Pro user keeps their engine choice.
///
/// Cloud is the engine Pro starts on, set once — at the first Pro activation on this Mac — and never again. Builds up
/// to 1.3.37 set it at every launch, every sign-in and every verification, so a Pro user's pick of on-device never
/// stuck. Now only a sign-in that turns Pro on may switch, and only while this Mac's flag (`AppSettings`'s
/// `proCloudDefaultApplied`, in its own defaults) is not set; after that, the user's pick in Settings is the only
/// writer of the engine. A second Mac has defaults of its own, so it gets cloud at its own first activation.
enum ProCloudDefault {
    /// The flag's key in the app's defaults.
    static let key = "proCloudDefaultApplied"
    /// Where the settings store the engine (`AppSettings.transcriptionEngine`): read as stored — nothing stored is no
    /// pick.
    static let engineKey = "transcriptionEngine"
    /// That this build has launched on this Mac and made its one check of an earlier build's choice.
    static let legacyCheckedKey = "proCloudDefaultLegacyChecked"

    /// A sign-in turned Pro on (`LicenseService.activate`): cloud the first time on this Mac, the user's choice after.
    static func activated(_ settings: AppSettings = .shared) {
        guard !settings.proCloudDefaultApplied else { return }
        settings.transcriptionEngine = "cloud"
        settings.proCloudDefaultApplied = true
        NSLog("[License] ☁️ first Pro activation on this Mac — cloud transcription set, once")
    }

    /// Pro was found on, not turned on: a session restored at launch, or a verification. It was activated on this Mac
    /// before — builds up to 1.3.37 set cloud then — so the choice stays, and only the flag is written.
    static func confirmed(_ settings: AppSettings = .shared) {
        if !settings.proCloudDefaultApplied { settings.proCloudDefaultApplied = true }
    }

    /// The launch (`LicenseService.init`, before any sign-in can run): a restored Pro session confirms an earlier
    /// activation; and the first launch of this build on a Mac records an engine stored as on-device as the user's own
    /// pick, whatever the licence says now. Builds up to 1.3.37 wrote cloud for Pro at every launch and sign-in, and
    /// on-device is the default, which is stored only when picked — so a stored on-device is a pick, made by a Pro
    /// user who then signed out, or by a Free one; the sign-in after the update keeps it (Codex, 1.4.0 review). A new
    /// install stores no engine, so its first activation still sets cloud once. The check runs once per Mac: a pick
    /// stored at a later launch is A1's as for any new user.
    static func launched(proRestored: Bool, _ settings: AppSettings = .shared, defaults: UserDefaults = .standard) {
        if proRestored { confirmed(settings) }
        guard !defaults.bool(forKey: legacyCheckedKey) else { return }
        defaults.set(true, forKey: legacyCheckedKey)
        guard defaults.string(forKey: engineKey) == "ondevice", !settings.proCloudDefaultApplied else { return }
        settings.proCloudDefaultApplied = true
        NSLog("[License] A1 — on-device was picked before this build: the next sign-in keeps it")
    }
}
