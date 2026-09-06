import Foundation
import IOKit

/// Manages Pro license state: activation via deep link, persistence, and verification.
@MainActor
final class LicenseService: ObservableObject {
    static let shared = LicenseService()

    /// Unique hardware UUID for this Mac (IOPlatformUUID)
    static let machineId: String = {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return UUID().uuidString // fallback
        }
        return uuid
    }()

    @Published var isPro: Bool = false
    @Published var email: String?
    @Published var licenseKey: String?
    @Published var plan: String?
    @Published var renewalDate: Date?
    @Published var cancelAtPeriodEnd: Bool = false
    @Published var isActivating: Bool = false
    @Published var lastError: String?

    /// LIC-1 — when the server last confirmed an active subscription. Drives the
    /// cached-Pro grace TTL (see `LicenseEntitlement`). Persisted in the Keychain.
    @Published var lastVerifiedAt: Date?

    private let api = "https://api.metawhisp.com"
    private static let lastVerifiedKey = "com.metawhisp.lastVerifiedAt"
    /// ITER-052 — 12h re-verify so the cached-Pro TTL is enforced in
    /// long-running sessions (menu-bar app runs for weeks between relaunches).
    private var reverifyTimer: Timer?
    /// ITER-052 (Codex) — one-shot re-verify AT the stamp's 72h expiry, so the
    /// bound ends at 72h sharp, not at the next 12h tick (worst case was 84h).
    private var expiryReverifyTimer: Timer?

    /// Re-verify against the server after `seconds` (one-shot). Used to land
    /// exactly on the cached-Pro grace expiry.
    private func scheduleExpiryReverify(after seconds: TimeInterval) {
        expiryReverifyTimer?.invalidate()
        expiryReverifyTimer = Timer.scheduledTimer(withTimeInterval: max(seconds, 1), repeats: false) { _ in
        NSLog("[License] 72h grace-expiry re-verify tick — cached Pro is dropped unless the server confirms now")
            Task { @MainActor in
                let s = LicenseService.shared
                if let t = KeychainHelper.load(key: "com.metawhisp.sessionToken"), !t.isEmpty {
                    await s.verify(token: t)
                }
            }
        }
    }

    private init() {
        // Restore from secure storage
        let token = KeychainHelper.load(key: "com.metawhisp.sessionToken")
        email = KeychainHelper.load(key: "com.metawhisp.proEmail")
        licenseKey = KeychainHelper.load(key: "com.metawhisp.licenseKey")
        plan = KeychainHelper.load(key: "com.metawhisp.proPlan")
        lastVerifiedAt = Self.loadLastVerified()
        // LIC-1 — cached Pro is trusted only within the grace TTL when the flag is
        // on; with the flag off (default) this is exactly `key present` — today's
        // behaviour. `verify()` below re-confirms with the server when online.
        let hasKey = licenseKey != nil && !(licenseKey?.isEmpty ?? true)
        isPro = LicenseEntitlement.cachedProIsTrusted(
            hasActiveKey: hasKey,
            lastVerifiedAt: lastVerifiedAt,
            now: Date(),
            enforce: AppSettings.shared.enforceProEntitlementTTL
        )

        // Auto-switch to cloud if Pro (skip loading 3-4 GB local model)
        if isPro && AppSettings.shared.transcriptionEngine == "ondevice" {
            AppSettings.shared.transcriptionEngine = "cloud"
            NSLog("[License] ☁️ Pro user detected at launch — auto-switched to cloud")
        }

        // Verify license is still valid on launch
        NSLog("[License] Launch state: pro=%@, key=%@, stamp=%@, launchVerify=%@", isPro ? "YES" : "NO", hasKey ? "present" : "none", lastVerifiedAt.map { String(format: "%.1fh ago", Date().timeIntervalSince($0) / 3600) } ?? "never", (token?.isEmpty == false) ? "scheduled" : "skipped (no session token)")
        if let token, !token.isEmpty {
            Task { await verify(token: token) }
        }

        // ITER-052 (Codex review) — the ≤72h cached-Pro bound must hold in
        // long-running menu-bar sessions too, not just across relaunches:
        // re-verify every 12h. A dead token keeps 401-ing → rejectionAction
        // re-evaluates the stamp against the TTL each pass, so a cancelled
        // account loses client-side Pro within the grace window even if the
        // app never restarts. (No-op when signed out — the token is empty.)
        reverifyTimer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in
        NSLog("[License] 12h re-verify tick")
            Task { @MainActor in
                let s = LicenseService.shared
                if let t = KeychainHelper.load(key: "com.metawhisp.sessionToken"), !t.isEmpty {
                    await s.verify(token: t)
                }
            }
        }
    }

    /// Activate Pro via deep link token from website.
    func activate(token: String) async {
        isActivating = true
        NSLog("[License] Activation START — deep-link token %d chars", token.count)
        lastError = nil

        // AUD-025 — never log token material (NSLog goes to a durable file).
        do {
            // AUD-025 — the token goes in the Authorization header, NOT the URL
            // query string. URLs leak to server / proxy / observability logs.
            let url = URL(string: "\(api)/api/auth/session?machine_id=\(Self.machineId)&activate=1")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("[License] ❌ Activation rejected — HTTP %d, body %d chars", (response as? HTTPURLResponse)?.statusCode ?? -1, body.count)
                NSLog("[License] ❌ HTTP error: %@", body)
                lastError = "Activation failed. Try signing in again."
                isActivating = false
                return
            }

            let result = try JSONDecoder().decode(SessionResponse.self, from: data)

            // Save to Keychain
            KeychainHelper.save(key: "com.metawhisp.sessionToken", value: token)
            KeychainHelper.save(key: "com.metawhisp.proEmail", value: result.email)

            email = result.email

            if let license = result.license, license.status == "active" {
                KeychainHelper.save(key: "com.metawhisp.licenseKey", value: license.licenseKey)
                KeychainHelper.save(key: "com.metawhisp.proPlan", value: license.plan)
                licenseKey = license.licenseKey
                plan = license.plan
                isPro = true
                recordVerified()   // LIC-1 — server confirmed active now
                // Store subscription dates
                if let sub = result.subscription, let end = sub.currentPeriodEnd {
                    renewalDate = Date(timeIntervalSince1970: end)
                    cancelAtPeriodEnd = sub.cancelAtPeriodEnd ?? false
                }
                // Auto-switch to cloud transcription for Pro (saves ~3-4 GB RAM)
                if AppSettings.shared.transcriptionEngine == "ondevice" {
                    AppSettings.shared.transcriptionEngine = "cloud"
                    NSLog("[License] ☁️ Auto-switched to cloud transcription for Pro user")
                }
                NSLog("[License] ✅ Pro activated: %@ (%@)", result.email, license.plan)
            } else {
                // Signed in but no active subscription.
                // AUD-026 — clear the persisted license too, not just memory.
                clearInactiveLicense()
                NSLog("[License] Signed in as %@ — no active subscription", result.email)
            }

            isActivating = false
        } catch {
            NSLog("[License] ❌ Activation error: %@", error.localizedDescription)
            lastError = "Connection error. Check your internet."
            isActivating = false
        }
    }

    /// ITER-050 B1.2 — sign-out policy for session verification. Pure and
    /// static so `SessionVerifyPolicyTests` can pin it: 401/403 are the only
    /// statuses that mean "this token is truly invalid"; everything else
    /// (5xx, 429, gateway hiccups) keeps the cached license, exactly like the
    /// offline catch branch below.
    nonisolated static func shouldSignOutOnVerify(httpStatus: Int) -> Bool {
        httpStatus == 401 || httpStatus == 403
    }

    /// ITER-052 — what `verify()` should do with a rejection. Fixes the
    /// every-relaunch logout: the app stores the one-time deep-link activation
    /// token as its session token and reuses it for `verify()`; once that token
    /// expires the server returns 401 on EVERY launch, and the old code called
    /// `signOut()` — wiping a paying user's license each time.
    ///
    /// A 401/403 proves only that the TOKEN can't authenticate — NOT that the
    /// subscription lapsed (the authoritative "not subscribed" signal is a
    /// `200 + inactive license`, handled by `clearInactiveLicense`). So:
    ///   - transient / non-authoritative (5xx, 429, offline) → `.keepQuiet`
    ///   - 401/403 while a trusted cached Pro exists          → `.keepCachedPro`
    ///   - 401/403 with nothing cached to fall back on        → `.signOut`
    enum VerifyRejection: Equatable { case keepQuiet, keepCachedPro, signOut }

    nonisolated static func rejectionAction(httpStatus: Int, hasTrustedCachedLicense: Bool) -> VerifyRejection {
        guard shouldSignOutOnVerify(httpStatus: httpStatus) else { return .keepQuiet }
        return hasTrustedCachedLicense ? .keepCachedPro : .signOut
    }

    /// ITER-061 (2026-08-07, «почему опять разлогинило») — root cause of the
    /// recurring 72h logout: the stored session token is a ONE-TIME deep-link
    /// credential the server eventually expires, so verify() can never succeed
    /// again; the stamp ages out and the grace path force-signs-out a PAYING
    /// user. The durable credential is the LICENSE KEY — the worker validates
    /// it against D1 on every /api/pro/* call. On a token rejection we now ask
    /// the license-key-gated `/api/usage` endpoint, which is authoritative for
    /// «is this subscription active»:
    ///   2xx     → active: refresh the stamp, keep Pro (no logout, ever)
    ///   401/403 → license revoked/inactive: sign out (the only real logout)
    ///   else    → inconclusive (5xx/offline): fall back to the stamp TTL
    nonisolated static func licenseKeyFallbackAction(usageStatus: Int) -> VerifyRejection {
        if (200 ..< 300).contains(usageStatus) { return .keepCachedPro }
        if usageStatus == 401 || usageStatus == 403 { return .signOut }
        return .keepQuiet
    }

    /// HTTP status of a license-key probe against `/api/usage` (-1 on network
    /// failure). AUD-025 — key rides in the Authorization header, not the URL.
    private func probeLicenseKey(_ key: String) async -> Int {
        guard let url = URL(string: "\(api)/api/usage") else { return -1 }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode ?? -1
        } catch { return -1 }
    }

    /// ITER-060.3 (Codex) — serialize verifications. The 12h timer and the
    /// expiry timer can fire together; two interleaved verify() runs raced to
    /// an inconsistent state (one path signOut-wiping the Keychain while the
    /// other set isPro=true from stale locals). MainActor + this flag = only
    /// one verification in flight; a concurrent request is simply skipped
    /// (the surviving run reaches the same authoritative answer).
    private var verifyInFlight = false

    /// Verify existing session token is still valid.
    private func verify(token: String) async {
        guard !verifyInFlight else {
            NSLog("[License] verify already in flight — skipping concurrent run")
            return
        }
        verifyInFlight = true
        NSLog("[License] verify START — key=%@, stamp=%@", (licenseKey?.isEmpty == false) ? "present" : "none", lastVerifiedAt.map { String(format: "%.1fh ago", Date().timeIntervalSince($0) / 3600) } ?? "never")
        defer { verifyInFlight = false }
        do {
            // AUD-025 — token in the Authorization header, not the URL.
            let url = URL(string: "\(api)/api/auth/session?machine_id=\(Self.machineId)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                // ITER-052 — a token rejection (401/403) must NOT wipe a valid
                // cached Pro license. The stored session token is the one-time
                // deep-link activation token; once it expires the server 401s on
                // every launch, and the old code signed the paying user out each
                // time. Only sign out when there's nothing cached to keep.
                // (ITER-050 B1.2 kept transient 5xx from destroying Pro; this
                // extends the same "don't nuke on an ambiguous signal" logic to
                // an auth rejection that a cached license can outlive.)
                // Codex review — bound the grace on a persistent auth rejection,
                // but stamp-awarely to avoid the two opposite failure modes:
                //   • stamp PRESENT → force the 72h TTL (enforce:true) even if
                //     the global flag is off, so a cancelled/dead-token user
                //     can't keep Pro forever (the "200 + inactive" can never
                //     arrive through a token that keeps 401-ing). They stay Pro
                //     for ≤72h from the last successful verify, then re-auth.
                //   • stamp ABSENT (legacy pre-LIC-1 key, or a planted key) →
                //     fall back to the global flag, i.e. the exact launch-time
                //     trust rule: grandfather the user under the default
                //     (enforce off), fail-closed under strict (enforce on). We
                //     do NOT fabricate a verification stamp — that would trust
                //     an unconfirmed/planted key for a fresh window.
                // Offline users never reach here (they hit the network-error
                // catch below), so legit offline Pro is unaffected.
                // ITER-061 — before the stamp/TTL dance, let the DURABLE
                // credential answer. A dead session token with a LIVE license
                // key must never end in a logout (see licenseKeyFallbackAction).
                if Self.shouldSignOutOnVerify(httpStatus: status),
                   let key = licenseKey, !key.isEmpty {
                    let usageStatus = await probeLicenseKey(key)
                    switch Self.licenseKeyFallbackAction(usageStatus: usageStatus) {
                    case .keepCachedPro:
                        isPro = true
                        recordVerified()
                        NSLog("[License] Token rejected (HTTP %d) but license key is ACTIVE (usage %d) — Pro kept, stamp refreshed", status, usageStatus)
                        return
                    case .signOut:
                        NSLog("[License] Token rejected (HTTP %d) and license key is DEAD (usage %d) — signing out", status, usageStatus)
                        signOut()
                        return
                    case .keepQuiet:
                        // ITER-060.3 (Codex) — a LIVE key with an UNREACHABLE
                        // probe (worker 5xx/offline) must NEVER cascade into
                        // the stamp-TTL sign-out below: that recreated the 72h
                        // logout for paying users whenever our worker was down
                        // at exactly the stamp's expiry. Keep everything; the
                        // 12h re-verify (or next launch) re-probes, and a truly
                        // dead key still ends in the 401/403 → signOut branch
                        // above once the worker answers.
                        NSLog("[License] Token rejected (HTTP %d), license probe inconclusive (usage %d) — keeping cached state, will re-probe", status, usageStatus)
                        return
                    }
                }
                let hasStamp = (lastVerifiedAt != nil)
                let hasCachedPro = LicenseEntitlement.cachedProIsTrusted(
                    hasActiveKey: (licenseKey?.isEmpty == false),
                    lastVerifiedAt: lastVerifiedAt,
                    now: Date(),
                    enforce: hasStamp ? true : AppSettings.shared.enforceProEntitlementTTL
                )
                switch Self.rejectionAction(httpStatus: status, hasTrustedCachedLicense: hasCachedPro) {
                case .signOut:
                    NSLog("[License] Session rejected (HTTP %d), no cached license — clearing", status)
                    signOut()
                case .keepCachedPro:
                    // Keep EVERYTHING — isPro / licenseKey / plan AND the session
                    // token. Codex review: clearing the token would permanently
                    // disable verify() (init skips it when the token is empty),
                    // so the app could never again receive the authoritative
                    // "200 + inactive license" that drops a cancelled sub. By
                    // keeping the token, every launch still re-verifies: a dead
                    // token just 401s harmlessly (we keep cached Pro), and the
                    // moment a valid session exists again the authoritative
                    // answer flows through and updates state normally.
                    NSLog("[License] Session token rejected (HTTP %d) — cached Pro still valid, keeping license + token", status)
                    // Land the NEXT check right after the grace expiry (+60s
                    // deliberate timer slack — firing a hair EARLY would keep
                    // Pro for another full cycle). Bound is 72h + ≤1 min, vs
                    // up to 84h with the fixed 12h tick alone. At that pass
                    // the stamp is past TTL → hasCachedPro=false → signOut.
                    if let last = lastVerifiedAt {
                        let remaining = LicenseEntitlement.defaultGraceTTL - Date().timeIntervalSince(last)
                        scheduleExpiryReverify(after: remaining + 60)
                    }
                case .keepQuiet:
                    NSLog("[License] Verify transient HTTP %d — keeping cached state", status)
                }
                return
            }

            let result = try JSONDecoder().decode(SessionResponse.self, from: data)
            email = result.email

            if let license = result.license, license.status == "active" {
                isPro = true
                recordVerified()   // LIC-1 — server confirmed active now
                licenseKey = license.licenseKey
                plan = license.plan
                KeychainHelper.save(key: "com.metawhisp.licenseKey", value: license.licenseKey)
                KeychainHelper.save(key: "com.metawhisp.proPlan", value: license.plan)
                // Match activate()/init: a verified Pro user runs on cloud (skips
                // the local model) and onboarding readiness reacts to the switch.
                if AppSettings.shared.transcriptionEngine == "ondevice" {
                    AppSettings.shared.transcriptionEngine = "cloud"
                }
                if let sub = result.subscription, let end = sub.currentPeriodEnd {
                    renewalDate = Date(timeIntervalSince1970: end)
                    cancelAtPeriodEnd = sub.cancelAtPeriodEnd ?? false
                }
            } else {
                // AUD-026 — authoritative inactive response (HTTP 200, no active
                // license): clear the PERSISTED license too, so a later offline
                // launch can't restore a stale Pro from the Keychain.
                clearInactiveLicense()
            }

            NSLog("[License] Verified: %@, pro=%@", result.email, isPro ? "YES" : "NO")
        } catch {
            NSLog("[License] Verify failed (offline?): %@", error.localizedDescription)
            // Keep existing state if offline
        }
    }

    /// AUD-026 — react to an authoritative "not subscribed" response (HTTP 200,
    /// no active license). Clears the persisted license key and plan in addition
    /// to in-memory state, so a later offline launch can't restore a stale Pro
    /// from the Keychain. The session token and email are intentionally kept (the
    /// user is still signed in, just not subscribed), and the offline grace path
    /// in `verify`'s catch block — which keeps existing state — is untouched.
    private func clearInactiveLicense() {
    NSLog("[License] Server says NOT subscribed — dropping Pro (was pro=%@, key=%@, stamp=%@)", isPro ? "YES" : "NO", (licenseKey?.isEmpty == false) ? "present" : "none", lastVerifiedAt == nil ? "never" : "set")
        isPro = false
        licenseKey = nil
        plan = nil
        renewalDate = nil
        cancelAtPeriodEnd = false
        clearVerified()   // LIC-1 — no active subscription → drop the verified stamp
        KeychainHelper.save(key: "com.metawhisp.licenseKey", value: "")
        KeychainHelper.save(key: "com.metawhisp.proPlan", value: "")
    }

    // MARK: - LIC-1 — server-verification timestamp (Keychain-persisted)

    private static func loadLastVerified() -> Date? {
        guard let s = KeychainHelper.load(key: lastVerifiedKey),
              let t = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private func recordVerified() {
        let now = Date()
        lastVerifiedAt = now
        KeychainHelper.save(key: Self.lastVerifiedKey, value: String(now.timeIntervalSince1970))
    }

    private func clearVerified() {
        lastVerifiedAt = nil
        KeychainHelper.save(key: Self.lastVerifiedKey, value: "")
    }

    // MARK: - ITER-056 — meeting-minutes meter (Settings → Account)

    /// Current-period usage as the worker reports it. Meetings-only: dictations
    /// never consume minutes (worker gate exempts short metered audio).
    struct UsageInfo: Equatable {
        let used: Double
        let limit: Double
        let balance: Double
        let periodStart: String?
    }

    @Published var usage: UsageInfo?

    /// Pure + static so the response contract is unit-tested without network.
    nonisolated static func parseUsage(_ data: Data) -> UsageInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let used = obj["used"] as? Double,
              let limit = obj["limit"] as? Double,
              let balance = obj["balance"] as? Double else { return nil }
        return UsageInfo(used: used, limit: limit, balance: balance,
                         periodStart: obj["period_start"] as? String)
    }

    /// Refresh the meter. AUD-025 (Codex review) — the key rides in the
    /// Authorization HEADER, never the URL: request targets end up in
    /// proxy/access logs. The worker accepts both; we only use the header.
    func fetchUsage() async {
        guard let key = licenseKey, !key.isEmpty,
              let url = URL(string: "\(api)/api/usage") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            NSLog("[License] Usage meter HTTP %d — %d bytes", (resp as? HTTPURLResponse)?.statusCode ?? -1, data.count)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            if let parsed = Self.parseUsage(data) { usage = parsed }
            NSLog("[License] Usage meter: used=%.1f limit=%.1f balance=%.1f min", usage?.used ?? -1, usage?.limit ?? -1, usage?.balance ?? -1)
        } catch {
            // Meter is cosmetic — keep the last known value silently.
            NSLog("[License] ⚠️ Usage meter refresh failed — %@ (keeping last known value)", error.localizedDescription)
        }
    }

    /// ITER-054 — book a meeting's wall-clock minutes to the Pro quota ONCE.
    /// Meetings transcribe BOTH channels un-metered (`count_usage=false`) so the
    /// old dual-stream 2× double-count is gone; this posts the single real
    /// charge = the meeting's length (independent of who talked or how much).
    /// Best-effort: a failed log means at most one free meeting — never a crash
    /// and never a blocked save.
    func logMeetingUsage(minutes: Double) async {
    NSLog("[License] Usage booking START — %.1f min, key=%@", minutes, (licenseKey?.isEmpty == false) ? "present" : "MISSING (nothing will be booked)")
        guard minutes > 0, let key = licenseKey, !key.isEmpty else { return }
        guard let url = URL(string: "\(api)/api/usage") else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["license_key": key, "minutes": minutes])
        // Codex review — the booking is the ONLY charge for a meeting (all its
        // transcription chunks went out count_usage=false), so a non-2xx must
        // NOT be treated as success: URLSession doesn't throw on 4xx/5xx. Verify
        // the status, retry transient failures, and log an HONEST miss so an
        // uncharged meeting is visible instead of silently free.
        for attempt in 1...3 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 15
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<300).contains(code) {
                    NSLog("[License] ✅ Booked meeting usage: %.1f min", minutes)
                    return
                }
                NSLog("[License] ⚠️ usage booking HTTP %d (attempt %d/3) — %.1f min", code, attempt, minutes)
            } catch {
                NSLog("[License] ⚠️ usage booking error (attempt %d/3): %@", attempt, error.localizedDescription)
            }
            if attempt < 3 { try? await Task.sleep(for: .seconds(Double(attempt) * 2)) }
        }
        NSLog("[License] ❌ meeting usage NOT booked after 3 tries — %.1f min left uncharged", minutes)
    }

    /// Sign out and clear all stored credentials.
    func signOut() {
    NSLog("[License] Sign-out START — was pro=%@, key=%@, stamp=%@", isPro ? "YES" : "NO", (licenseKey?.isEmpty == false) ? "present" : "none", lastVerifiedAt == nil ? "never" : "set")
        KeychainHelper.save(key: "com.metawhisp.sessionToken", value: "")
        KeychainHelper.save(key: "com.metawhisp.proEmail", value: "")
        KeychainHelper.save(key: "com.metawhisp.licenseKey", value: "")
        KeychainHelper.save(key: "com.metawhisp.proPlan", value: "")
        isPro = false
        email = nil
        licenseKey = nil
        plan = nil
        renewalDate = nil
        cancelAtPeriodEnd = false
        clearVerified()   // LIC-1
        NSLog("[License] Signed out")
    }
}

// MARK: - API Response

private struct SessionResponse: Decodable {
    let email: String
    let license: LicenseInfo?
    let subscription: SubscriptionInfo?

    struct LicenseInfo: Decodable {
        let licenseKey: String
        let plan: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case licenseKey = "license_key"
            case plan
            case status
        }
    }

    struct SubscriptionInfo: Decodable {
        let currentPeriodEnd: Double?
        let cancelAtPeriodEnd: Bool?
        let status: String?

        enum CodingKeys: String, CodingKey {
            case currentPeriodEnd = "current_period_end"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case status
        }
    }
}
