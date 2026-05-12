import Foundation

/// Static catalog of local LLM models offered to Free-tier users for download
/// (ITER-039). Each `ModelSpec` is everything the Settings UI needs to render
/// a model card: characteristics for display, HF Hub coordinates for download,
/// and minimum specs for the compatibility badge.
///
/// **Verified 2026-05-12** that all `hfRepoID` values exist on
/// `huggingface.co/mlx-community`. Apple Foundation Models is a special case
/// (no download, no HF — provided by the OS on macOS 26+).
struct ModelSpec: Identifiable, Equatable {
    /// Stable internal identifier — used as folder name in
    /// `~/Library/Application Support/MetaWhisp/LocalLLM/<id>/`. Don't change.
    let id: String
    /// HuggingFace Hub repo ID. Empty for `isFoundationModels = true`.
    let hfRepoID: String
    /// Display name in Settings cards.
    let displayName: String
    /// Vendor (Microsoft / Google / Alibaba / Apple).
    let vendor: String
    /// Param count display string. E.g. «3.8 B», «4 B», «E2B effective».
    let paramsDisplay: String
    /// Quantization scheme label. E.g. «AWQ-4bit MLX», «TurboQuant-MLX».
    let quantization: String
    /// Approx download size in bytes (sourced from HF model card).
    /// Used for progress + storage display. ±5% acceptable.
    let downloadSizeBytes: Int64
    /// Peak RAM during inference, in GB. Compatibility check compares to host.
    let ramPeakGB: Int
    /// Approx output speed on M1 base, in tok/s. Used as «typical speed»
    /// indicator — actual will be 1-3× faster on newer chips.
    let speedM1TokPerSec: Int
    /// Quality rating 1-5 (subjective from public benchmarks).
    let quality: Int
    /// ISO language codes (or descriptive). e.g. ["EN", "RU", "multilingual"].
    let languages: [String]
    /// Minimum RAM (GB) for which we'd recommend this model. Compat check
    /// uses this as the threshold for «Recommended».
    let minRecommendedRAMGB: Int
    /// Hard RAM ceiling above which we'd flag «Too heavy» (model won't fit
    /// comfortably). Usually = ramPeakGB + ~2 GB headroom for the rest of the app.
    let hardMinRAMGB: Int
    /// Minimum chip generation. 0 = any (incl. Intel). 1 = M1+. Etc.
    let minChipGen: Int
    /// One-line «best for» tagline shown on the card.
    let bestForTagline: String
    /// `true` for Apple's built-in Foundation Models — no download required.
    let isFoundationModels: Bool

    /// Human-readable size for UI: «2.2 GB», «1.5 GB», «—» for built-in.
    var downloadSizeDisplay: String {
        if isFoundationModels { return "—" }
        let gb = Double(downloadSizeBytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gb)
    }
}

enum ModelRegistry {

    /// The 5 models offered to users in ITER-039.
    /// Order matters — Settings UI renders this top-to-bottom. Default
    /// recommendation first.
    static let allModels: [ModelSpec] = [
        // ─── Default ───────────────────────────────────────────────────
        ModelSpec(
            id: "phi-4-mini",
            hfRepoID: "mlx-community/Phi-4-mini-instruct-4bit",
            displayName: "Phi-4 Mini Instruct",
            vendor: "Microsoft",
            paramsDisplay: "3.8 B",
            quantization: "AWQ-4bit MLX",
            downloadSizeBytes: 2_300_000_000,   // ~2.2 GB
            ramPeakGB: 3,
            speedM1TokPerSec: 135,
            quality: 5,
            languages: ["EN", "RU", "multilingual"],
            minRecommendedRAMGB: 8,
            hardMinRAMGB: 8,
            minChipGen: 1,
            bestForTagline: "Default — general purpose, balanced",
            isFoundationModels: false
        ),

        // ─── Lightweight (fastest) ─────────────────────────────────────
        ModelSpec(
            id: "gemma-4-e2b",
            hfRepoID: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B",
            vendor: "Google",
            paramsDisplay: "E2B effective",
            quantization: "TurboQuant-MLX",
            downloadSizeBytes: 1_600_000_000,   // ~1.5 GB
            ramPeakGB: 5,
            speedM1TokPerSec: 158,
            quality: 4,
            languages: ["EN", "multilingual (limited)"],
            minRecommendedRAMGB: 8,
            hardMinRAMGB: 8,
            minChipGen: 1,
            bestForTagline: "Fastest responses, mobile-class Macs",
            isFoundationModels: false
        ),

        // ─── Multilingual (best Russian) ───────────────────────────────
        ModelSpec(
            id: "qwen3-4b",
            hfRepoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen 3 4B Instruct",
            vendor: "Alibaba",
            paramsDisplay: "4 B",
            quantization: "AWQ-4bit MLX",
            downloadSizeBytes: 2_500_000_000,   // ~2.3 GB
            ramPeakGB: 3,
            speedM1TokPerSec: 80,
            quality: 5,
            languages: ["RU (best)", "EN", "multilingual"],
            minRecommendedRAMGB: 8,
            hardMinRAMGB: 8,
            minChipGen: 1,
            bestForTagline: "Heavy Russian dictation, multilingual users",
            isFoundationModels: false
        ),

        // ─── Quality (best, but heavier) ────────────────────────────────
        ModelSpec(
            id: "qwen3-7b",
            hfRepoID: "mlx-community/Qwen3-7B-Instruct-2507-4bit",
            displayName: "Qwen 3 7B Instruct",
            vendor: "Alibaba",
            paramsDisplay: "7 B",
            quantization: "AWQ-4bit MLX",
            downloadSizeBytes: 4_500_000_000,   // ~4.2 GB
            ramPeakGB: 6,
            speedM1TokPerSec: 50,
            quality: 5,
            languages: ["EN", "RU", "multilingual excellent"],
            minRecommendedRAMGB: 16,
            hardMinRAMGB: 10,
            minChipGen: 1,
            bestForTagline: "Highest quality (HumanEval 76.0) — needs 16 GB+",
            isFoundationModels: false
        ),

        // ─── Built-in (macOS 26+) ──────────────────────────────────────
        ModelSpec(
            id: "apple-foundation-models",
            hfRepoID: "",
            displayName: "Apple Foundation Models",
            vendor: "Apple",
            paramsDisplay: "~3 B equivalent",
            quantization: "native (Apple Neural Engine)",
            downloadSizeBytes: 0,
            ramPeakGB: 2,
            speedM1TokPerSec: 0,                // varies; «native» speed
            quality: 4,
            languages: ["EN", "Apple-supported languages"],
            minRecommendedRAMGB: 8,
            hardMinRAMGB: 8,
            minChipGen: 1,
            bestForTagline: "Zero download, zero config — macOS 26+ only",
            isFoundationModels: true
        ),
    ]

    /// Lookup by `id`. Used by AppSettings.localLLMActiveModelID → resolve.
    static func model(byID id: String) -> ModelSpec? {
        return allModels.first { $0.id == id }
    }
}

// MARK: - Compatibility verdict

/// «Will this model run on this Mac?» — three-tier verdict for the Settings
/// card badge. Drives green/yellow/red coloring + tooltip text.
enum CompatibilityVerdict: Equatable {
    /// Comfortable fit. Show green ✓ badge with «Recommended for your Mac».
    case recommended
    /// Will run but tight on RAM, slow on this chip, or both. Yellow ⚠ badge.
    case slow(reason: String)
    /// Won't fit / unsupported OS. Red ✗ badge, Download button disabled.
    case incompatible(reason: String)

    var isDownloadable: Bool {
        switch self {
        case .recommended, .slow: return true
        case .incompatible: return false
        }
    }
}

enum ModelCompatibility {

    /// Pure-function verdict. Takes spec + a closure-supplied system snapshot
    /// (so it's testable without touching `SystemSpecs` real I/O).
    static func verdict(
        for spec: ModelSpec,
        systemRAMGB: Int = SystemSpecs.totalRAMGB,
        systemChipGen: Int = SystemSpecs.chipGeneration,
        macOSMajor: Int = SystemSpecs.macOSVersion.major,
        isAppleSilicon: Bool = SystemSpecs.isAppleSilicon
    ) -> CompatibilityVerdict {

        // Foundation Models is a special case — no download, but needs OS support.
        if spec.isFoundationModels {
            if macOSMajor >= 26 {
                return .recommended
            }
            return .incompatible(
                reason: "Requires macOS 26+ (you're on macOS \(macOSMajor))"
            )
        }

        // MLX models require Apple Silicon — Intel Macs can't use them.
        if !isAppleSilicon {
            return .incompatible(reason: "Requires Apple Silicon (M-series Mac)")
        }

        // Chip generation gate (rare — most models work on M1+).
        if systemChipGen < spec.minChipGen {
            return .incompatible(
                reason: "Requires M\(spec.minChipGen)+ chip (you have M\(systemChipGen))"
            )
        }

        // RAM hard floor.
        if systemRAMGB < spec.hardMinRAMGB {
            return .incompatible(
                reason: "Needs at least \(spec.hardMinRAMGB) GB RAM (you have \(systemRAMGB) GB)"
            )
        }

        // Soft recommendation gate.
        if systemRAMGB < spec.minRecommendedRAMGB {
            return .slow(
                reason: "Tight on \(systemRAMGB) GB — try the lighter Gemma 4 E2B first"
            )
        }

        return .recommended
    }
}
