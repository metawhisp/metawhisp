import Foundation
import IOKit
import IOKit.ps

/// Read-only snapshot of the host Mac's hardware + OS for compatibility
/// decisions (which local LLM models fit comfortably). Values resolved lazily
/// + cached for the process lifetime — these don't change at runtime.
///
/// Added 2026-05-12 for ITER-039 (Local LLM for Free tier). The download UI
/// uses this to badge each model card as «Recommended / Slow / Too heavy
/// for your Mac».
enum SystemSpecs {

    /// Human-readable chip name, e.g. «M1 Pro», «M3 Max», «M5 Max».
    /// Falls back to `sysctl hw.model` (raw machine model) if the chip
    /// can't be resolved through `kIOPlatformExpertDevice`.
    static let chipName: String = {
        // Try IORegistry first — gives clean «Apple M2 Pro» style on modern macOS.
        if let raw = ioRegistryString(key: "product-name") {
            // e.g. «MacBook Pro» — not the chip, but useful fallback.
            // Actual chip lives in 'compatible' as 'apple,t6020' codes; messy.
            // Better path: hw.optional.arm.FEAT_ via sysctl or just brand string.
            _ = raw
        }
        // Use sysctl machdep.cpu.brand_string — most reliable on Apple Silicon.
        if let brand = sysctlString(name: "machdep.cpu.brand_string") {
            // Returns e.g. «Apple M2 Pro» on Apple Silicon, «Intel(R) Core(TM)...» on Intel.
            return brand.replacingOccurrences(of: "Apple ", with: "")
        }
        // Last resort.
        return sysctlString(name: "hw.model") ?? "Unknown"
    }()

    /// True iff the host runs on Apple Silicon (any M-series). False for Intel.
    static let isAppleSilicon: Bool = {
        if let result = sysctlString(name: "machdep.cpu.brand_string") {
            return result.lowercased().hasPrefix("apple")
        }
        // Fallback — check via `hw.optional.arm64`.
        return sysctlInt(name: "hw.optional.arm64") == 1
    }()

    /// Approximate generation number: 1 for M1*, 2 for M2*, 3 for M3*, 4 for M4*,
    /// 5 for M5*, 0 for Intel / unknown. Used by compatibility checks — newer
    /// generations are faster per-watt and run larger models well.
    static let chipGeneration: Int = {
        let name = chipName.uppercased()
        for gen in 1...9 {
            if name.contains("M\(gen)") { return gen }
        }
        return 0
    }()

    /// Total physical RAM in bytes.
    static let totalRAMBytes: Int64 = {
        return Int64(ProcessInfo.processInfo.physicalMemory)
    }()

    /// Total physical RAM rounded to nearest GB. Used everywhere the user-
    /// facing UI displays «8 GB», «16 GB», etc.
    static let totalRAMGB: Int = {
        let gb = Double(totalRAMBytes) / 1_073_741_824.0  // 1024^3
        return Int(gb.rounded())
    }()

    /// macOS major.minor version, e.g. (14, 5) or (26, 0).
    /// 26 = the «Foundation Models» threshold (Apple's built-in LLM API).
    static let macOSVersion: (major: Int, minor: Int) = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion)
    }()

    /// Whether Apple's built-in `LanguageModel` API (FoundationModels framework)
    /// is available on this OS. macOS 26+ ships ~3B-equivalent model on-device.
    /// When true, ITER-039 prefers it over any downloadable model — zero cost,
    /// zero download, Apple-managed updates.
    static let supportsFoundationModels: Bool = {
        return macOSVersion.major >= 26
    }()

    /// One-shot human-readable description for the «AI Models» section header
    /// or compatibility badges: «M2 Pro · 16 GB · macOS 14.5».
    static var summary: String {
        let chip = chipName
        let ram = "\(totalRAMGB) GB"
        let os = "macOS \(macOSVersion.major).\(macOSVersion.minor)"
        return "\(chip) · \(ram) · \(os)"
    }

    // MARK: - sysctl helpers

    /// Read a string-valued sysctl by name. Returns nil if missing.
    private static func sysctlString(name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: bytes)
    }

    /// Read an int-valued sysctl by name. Returns 0 if missing.
    private static func sysctlInt(name: String) -> Int {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 {
            return value
        }
        return 0
    }

    /// Read an IORegistry property as String. Best-effort — kIOServicePlane
    /// scanning is finicky across macOS versions; reserved as fallback only.
    private static func ioRegistryString(key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0 else { return nil }
        guard let raw = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        if let s = raw as? String { return s }
        if let d = raw as? Data, let s = String(data: d, encoding: .utf8) {
            return s.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return nil
    }
}
