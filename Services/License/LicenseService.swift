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

    private let api = "https://api.metawhisp.com"

    private init() {
        // Restore from secure storage
        let token = KeychainHelper.load(key: "com.metawhisp.sessionToken")
        email = KeychainHelper.load(key: "com.metawhisp.proEmail")
        licenseKey = KeychainHelper.load(key: "com.metawhisp.licenseKey")
        plan = KeychainHelper.load(key: "com.metawhisp.proPlan")
        isPro = licenseKey != nil && !(licenseKey?.isEmpty ?? true)

        // Auto-switch to cloud if Pro (skip loading 3-4 GB local model)
        if isPro && AppSettings.shared.transcriptionEngine == "ondevice" {
            AppSettings.shared.transcriptionEngine = "cloud"
            NSLog("[License] ☁️ Pro user detected at launch — auto-switched to cloud")
        }

        // Verify license is still valid on launch
        if let token, !token.isEmpty {
            Task { await verify(token: token) }
        }
    }

    /// Activate Pro via deep link token from website.
    func activate(token: String) async {
        isActivating = true
        lastError = nil

        NSLog("[License] Activating with token: %@...", String(token.prefix(8)))

        do {
            let url = URL(string: "\(api)/api/auth/session?token=\(token)&machine_id=\(Self.machineId)&activate=1")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
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
                // Signed in but no active subscription
                isPro = false
                licenseKey = nil
                plan = nil
                renewalDate = nil
                cancelAtPeriodEnd = false
                NSLog("[License] Signed in as %@ — no active subscription", result.email)
            }

            isActivating = false
        } catch {
            NSLog("[License] ❌ Activation error: %@", error.localizedDescription)
            lastError = "Connection error. Check your internet."
            isActivating = false
        }
    }

    /// Verify existing session token is still valid.
    private func verify(token: String) async {
        do {
            let url = URL(string: "\(api)/api/auth/session?token=\(token)&machine_id=\(Self.machineId)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[License] Session expired, clearing")
                signOut()
                return
            }

            let result = try JSONDecoder().decode(SessionResponse.self, from: data)
            email = result.email

            if let license = result.license, license.status == "active" {
                isPro = true
                licenseKey = license.licenseKey
                plan = license.plan
                KeychainHelper.save(key: "com.metawhisp.licenseKey", value: license.licenseKey)
                KeychainHelper.save(key: "com.metawhisp.proPlan", value: license.plan)
                if let sub = result.subscription, let end = sub.currentPeriodEnd {
                    renewalDate = Date(timeIntervalSince1970: end)
                    cancelAtPeriodEnd = sub.cancelAtPeriodEnd ?? false
                }
            } else {
                isPro = false
                licenseKey = nil
                plan = nil
                renewalDate = nil
                cancelAtPeriodEnd = false
            }

            NSLog("[License] Verified: %@, pro=%@", result.email, isPro ? "YES" : "NO")
        } catch {
            NSLog("[License] Verify failed (offline?): %@", error.localizedDescription)
            // Keep existing state if offline
        }
    }

    /// Sign out and clear all stored credentials.
    func signOut() {
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
