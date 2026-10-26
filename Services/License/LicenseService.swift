import Foundation
import IOKit
import Security

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
    /// A2 — the subscription's billing period, "year" or "month", from the session answer (server S2); nil until
    /// a session answer says it. Every license row says plan "pro", so the plan name cannot tell.
    @Published var billingInterval: String?
    @Published var renewalDate: Date?
    @Published var cancelAtPeriodEnd: Bool = false
    @Published var isActivating: Bool = false
    @Published var lastError: String?
    /// Set while a saved Pro item exists but can't be read (ITER-075 step 0,
    /// US-0.4). Nothing is signed out or deleted while it is set.
    @Published var keychainProblem: String?
    /// Set when this session's sign-in could not be saved to the keychain; the
    /// sign-in banner says so instead of "Pro activated".
    @Published var unsavedSignIn: OSStatus?

    /// A non-secret note that the last sign-in could not be saved, so the next
    /// launch can say why the owner is signed out. Cleared by a sign-in that
    /// saves, a readable license key, or a sign-out.
    private static let unsavedSignInKey = "license.unsavedSignInStatus"
    private static var unsavedSignInStatus: OSStatus? {
        get { (UserDefaults.standard.object(forKey: unsavedSignInKey) as? Int).map { OSStatus(truncatingIfNeeded: $0) } }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: unsavedSignInKey)
            } else {
                UserDefaults.standard.removeObject(forKey: unsavedSignInKey)
            }
        }
    }

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
                if let t = s.tokenForReverify(), !t.isEmpty {
                    await s.verify(token: t)
                }
            }
        }
    }

    private init() {
        // Restore from secure storage. An item that exists but can't be read is
        // a keychain problem, never a sign-out (ITER-075 step 0, US-0.4).
        let token = restoreFromKeychain()
        let hasKey = licenseKey != nil && !(licenseKey?.isEmpty ?? true)

        // A1 — a restored Pro session was activated on this Mac before: the user's engine choice stays.
        ProCloudDefault.launched(proRestored: isPro)

        // Verify license is still valid on launch
        NSLog("[License] Launch state: pro=%@, key=%@, stamp=%@, keychain=%@, launchVerify=%@", isPro ? "YES" : "NO", hasKey ? "present" : "none", lastVerifiedAt.map { String(format: "%.1fh ago", Date().timeIntervalSince($0) / 3600) } ?? "never", keychainProblem == nil ? "ok" : "UNREADABLE", (token?.isEmpty == false) ? "scheduled" : "skipped (no session token, or the keychain is unreadable)")
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
                if let t = s.tokenForReverify(), !t.isEmpty {
                    await s.verify(token: t)
                }
            }
        }
    }

    /// Reads the saved Pro session and returns its token, if any.
    ///
    /// An item that exists but can't be read sets `keychainProblem` and
    /// changes nothing else: no field is cleared, nothing is deleted, and no
    /// verification runs — a verify could end in `signOut()`, which deletes
    /// the very items that could not be read. The next read that succeeds
    /// clears the problem: the 12h re-verify reads again while it is set, and
    /// so does every launch.
    private func restoreFromKeychain() -> String? {
        var reads: [String: KeychainRead] = [:]
        for account in LicenseRestore.accounts { reads[account] = KeychainHelper.read(account) }
        let decision = LicenseRestore.decide(reads)
        let launch = LicenseRestore.launchPlan(decision, unsavedStatus: Self.unsavedSignInStatus)
        if launch.clearUnsavedMarker { Self.unsavedSignInStatus = nil }
        switch decision {
        case .unreadable(let account, let status):
            keychainProblem = launch.message
            lastError = launch.message
            NSLog("[License] ❌ keychain item %@ unreadable (status %d) — nothing deleted, verify skipped", account, status)
        case .restored(_, let restoredEmail, let restoredKey, let restoredPlan, let stamp):
            if let problem = keychainProblem {
                NSLog("[License] keychain readable again — Pro session restored")
                if lastError == problem { lastError = nil }
            }
            keychainProblem = nil
            if let message = launch.message {
                lastError = message
                NSLog("[License] the last sign-in was not saved to the keychain — signed out, and the owner is told why")
            }
            email = restoredEmail
            licenseKey = restoredKey
            plan = restoredPlan
            lastVerifiedAt = stamp.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
            // LIC-1 — cached Pro is trusted only within the grace TTL when the flag is
            // on; with the flag off (default) this is exactly `key present` — today's
            // behaviour. `verify()` re-confirms with the server when online.
            let hasKey = licenseKey != nil && !(licenseKey?.isEmpty ?? true)
            isPro = LicenseEntitlement.cachedProIsTrusted(
                hasActiveKey: hasKey,
                lastVerifiedAt: lastVerifiedAt,
                now: Date(),
                enforce: AppSettings.shared.enforceProEntitlementTTL
            )
        }
        return launch.verifyToken
    }

    /// The session token for a scheduled re-verify. While the keychain was
    /// unreadable, every Pro item is read again first — a read that succeeds
    /// now is what ends the problem (every gate needs a release).
    private func tokenForReverify() -> String? {
        keychainProblem != nil ? restoreFromKeychain() : KeychainHelper.load(key: "com.metawhisp.sessionToken")
    }

    /// The activation's request to the session endpoint: the network in the app; a test's own answer in tests.
    nonisolated static let networkActivation: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }
    var sendActivation: @Sendable (URLRequest) async throws -> (Data, URLResponse) = LicenseService.networkActivation

    /// Activate Pro via deep link token from website. True when the server accepted the token — the account is
    /// signed in for this session, whether or not the keychain kept it (a refusal is told through `unsavedSignIn` and
    /// `lastError`); false when the server refused it, its answer could not be read, or there was none. A sign-in
    /// link's press is spent on true and given back on false (A3).
    @discardableResult
    func activate(token: String) async -> Bool {
        isActivating = true
        NSLog("[License] Activation START — deep-link token %d chars", token.count)
        lastError = nil
        unsavedSignIn = nil

        // AUD-025 — never log token material (NSLog goes to a durable file).
        do {
            // AUD-025 — the token goes in the Authorization header, NOT the URL
            // query string. URLs leak to server / proxy / observability logs.
            let url = URL(string: "\(api)/api/auth/session?machine_id=\(Self.machineId)&activate=1")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            let (data, response) = try await sendActivation(request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                NSLog("[License] ❌ Activation rejected — HTTP %d, body %d chars", (response as? HTTPURLResponse)?.statusCode ?? -1, body.count)
                NSLog("[License] ❌ HTTP error — %@", LLMRequestBody.proxyReason(data))
                lastError = "Activation failed. Try signing in again."
                isActivating = false
                return false
            }

            let result = try JSONDecoder().decode(SessionResponse.self, from: data)

            // Save to Keychain. Every write is checked: a sign-in the keychain
            // refused must not report success and then vanish at the next launch.
            // The durable credential (the license key) is written first and the
            // one-time session token last, so a save cut short leaves a usable
            // key — never a lone token whose next 401 would sign out.
            var failedWrite: OSStatus?
            func note(_ status: OSStatus) {
                if status != errSecSuccess, failedWrite == nil { failedWrite = status }
            }

            if let license = result.license, license.status == "active" {
                note(KeychainHelper.save(key: "com.metawhisp.licenseKey", value: license.licenseKey))
                note(KeychainHelper.save(key: "com.metawhisp.proPlan", value: license.plan))
                licenseKey = license.licenseKey
                plan = license.plan
                isPro = true
                note(recordVerified())   // LIC-1 — server confirmed active now
                billingInterval = result.subscription?.interval
                // Store subscription dates
                if let sub = result.subscription, let end = sub.currentPeriodEnd {
                    renewalDate = Date(timeIntervalSince1970: end)
                    cancelAtPeriodEnd = sub.cancelAtPeriodEnd ?? false
                }
                // A1 — cloud on this Mac's first Pro activation; the user's choice on any later one.
                ProCloudDefault.activated()
                NSLog("[License] ✅ Pro activated — plan=%@ (account identified, address not logged)", license.plan)
            } else {
                // Signed in but no active subscription.
                // AUD-026 — clear the persisted license too, not just memory.
                clearInactiveLicense()
                NSLog("[License] signed in — no active subscription (address not logged)")
            }
            note(KeychainHelper.save(key: "com.metawhisp.proEmail", value: result.email))
            note(KeychainHelper.save(key: "com.metawhisp.sessionToken", value: token))
            email = result.email

            // The server has answered: this session is newer than anything the
            // keychain held, so a problem found at launch no longer applies, and a
            // re-verify tick must not "restore" over it.
            keychainProblem = nil
            unsavedSignIn = failedWrite
            Self.unsavedSignInStatus = failedWrite
            if let message = LicenseRestore.activationMessage(isPro: isPro, failedWrite: failedWrite) {
                lastError = message
                NSLog("[License] ❌ sign-in not saved — keychain status %d; it lasts this session only", failedWrite ?? 0)
            }
            isActivating = false
            return true
        } catch {
            NSLog("[License] ❌ Activation error: %@", error.localizedDescription)
            lastError = "Connection error. Check your internet."
            isActivating = false
            return false
        }
    }

    /// A3 — the account a sign-in link's token belongs to, asked without signing in: the session endpoint with no
    /// machine id, so no licence is bound to this Mac, and nothing here is stored or published.
    func account(ofSignInToken token: String) async -> SignInLink.Account {
        guard let url = URL(string: "\(api)/api/auth/session") else { return .unreachable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")   // AUD-025: never in the URL
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return Self.signInAccount(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
        } catch {
            NSLog("[License] sign-in link lookup failed: %@", error.localizedDescription)
            return .unreachable
        }
    }

    /// The lookup's answer: the session's address; a token the server refuses (missing, invalid or expired, its
    /// account gone) is a bad link; anything else could not be checked.
    nonisolated static func signInAccount(status: Int, data: Data) -> SignInLink.Account {
        if [400, 401, 403, 404].contains(status) { return .rejected }
        guard status == 200, let email = try? JSONDecoder().decode(SessionResponse.self, from: data).email,
              !email.isEmpty else { return .unreachable }
        return .email(email)
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
                // A1 — a verification confirms an earlier activation: the user's engine choice stays.
                ProCloudDefault.confirmed()
                if let sub = result.subscription, let end = sub.currentPeriodEnd {
                    renewalDate = Date(timeIntervalSince1970: end)
                    cancelAtPeriodEnd = sub.cancelAtPeriodEnd ?? false
                }
                billingInterval = result.subscription?.interval
            } else {
                // AUD-026 — authoritative inactive response (HTTP 200, no active
                // license): clear the PERSISTED license too, so a later offline
                // launch can't restore a stale Pro from the Keychain.
                clearInactiveLicense()
            }

            NSLog("[License] verified — pro=%@ (address not logged)", isPro ? "YES" : "NO")
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
        billingInterval = nil
        renewalDate = nil
        cancelAtPeriodEnd = false
        clearVerified()   // LIC-1 — no active subscription → drop the verified stamp
        KeychainHelper.save(key: "com.metawhisp.licenseKey", value: "")
        KeychainHelper.save(key: "com.metawhisp.proPlan", value: "")
    }

    // MARK: - LIC-1 — server-verification timestamp (Keychain-persisted)

    @discardableResult
    private func recordVerified() -> OSStatus {
        let now = Date()
        lastVerifiedAt = now
        return KeychainHelper.save(key: Self.lastVerifiedKey, value: String(now.timeIntervalSince1970))
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

    /// Settings' plan line, from the billing period. No period known, no line — never a guessed "Monthly".
    nonisolated static func planLabel(interval: String?) -> String? {
        switch interval {
        case "year": return "Annual plan"
        case "month": return "Monthly plan"
        default: return nil
        }
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
        billingInterval = nil
        renewalDate = nil
        cancelAtPeriodEnd = false
        clearVerified()   // LIC-1
        unsavedSignIn = nil
        Self.unsavedSignInStatus = nil
        NSLog("[License] Signed out")
    }
}

// MARK: - API Response

struct SessionResponse: Decodable {
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
        /// "year" or "month" (server S2); absent from older servers.
        let interval: String?

        enum CodingKeys: String, CodingKey {
            case currentPeriodEnd = "current_period_end"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case status
            case interval
        }
    }
}
