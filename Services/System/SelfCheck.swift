import Foundation
import MLX

/// ITER-075 step 0, US-0.2 — `MetaWhisp --self-check`, the release smoke test.
///
/// It checks that the bundle starts and finds its parts, then exits. It runs
/// from the entry point before the app exists (`Launch`), so it never opens
/// the store, the keychain or the log, never goes online and never captures
/// anything. The one thing it can add to is macOS's GPU shader cache for the
/// bundle id, which macOS keeps for several processes at once. That is why it
/// can run beside the owner's working app: the old smoke test launched a full
/// second copy with the working app's identity, which opened the owner's data
/// and needed the working app stopped.
///
/// It does not run the app's own startup code. A test build swapped onto the
/// owner's Mac (hot-swap.sh) runs that code first, before a release, with the
/// working app's own identity.
enum SelfCheck {
    static let argument = "--self-check"

    struct Check {
        let name: String
        /// nil when the check passes, otherwise what is wrong.
        let run: () -> String?
    }

    /// Only an argument after the program's own path asks for it.
    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }

    /// Runs the checks for this bundle and exits with their result. Every line
    /// reaches the caller at once, so a crash still leaves the lines before it,
    /// and a SIGTERM from a caller that gave up always ends the process, even
    /// when the caller itself ignores SIGTERM.
    static func runAndExit() -> Never {
        signal(SIGTERM, SIG_DFL)
        setvbuf(stdout, nil, _IOLBF, 0)
        exit(run())
    }

    /// Runs every check, prints one line per check and a verdict, and returns
    /// the exit code: 0 when every check passed.
    static func run(_ checks: [Check] = defaultChecks(bundle: .main),
                    print say: (String) -> Void = { print($0) }) -> Int32 {
        var failed = 0
        for check in checks {
            if let problem = check.run() {
                say("self-check: \(check.name) FAILED — \(problem)")
                failed += 1
            } else {
                say("self-check: \(check.name) ok")
            }
        }
        say(failed == 0 ? "SELF-CHECK OK" : "SELF-CHECK FAILED")
        return failed == 0 ? 0 : 1
    }

    static func defaultChecks(bundle: Bundle) -> [Check] {
        [
            Check(name: "Info.plist") { infoPlistProblem(bundle.infoDictionary ?? [:]) },
            Check(name: "mlx.metallib") { metallibProblem(executableURL: bundle.executableURL) },
            // Without its shaders MLX ends the process, which would cut this report short.
            Check(name: "MLX on the GPU") {
                metallibProblem(executableURL: bundle.executableURL) == nil ? mlxProblem() : "skipped — no mlx.metallib"
            },
        ]
    }

    /// The bundle names itself and its version; the working app also carries
    /// its update feed and key, without which it would never update again.
    static func infoPlistProblem(_ info: [String: Any]) -> String? {
        guard let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return "no bundle id" }
        guard info["CFBundleShortVersionString"] is String else { return "no version" }
        if AppIdentity(bundleIdentifier: id).updatesItself,
           !(info["SUFeedURL"] is String) || !(info["SUPublicEDKey"] is String) {
            return "no update feed or key"
        }
        return nil
    }

    /// MLX loads its shaders from mlx.metallib next to the executable; v1.3.5
    /// shipped without it and crashed on first use (2026-05-21).
    static func metallibProblem(executableURL: URL?) -> String? {
        guard let folder = executableURL?.deletingLastPathComponent() else { return "no executable path" }
        let file = folder.appendingPathComponent("mlx.metallib")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return size > 0 ? nil : "missing or empty at \(file.path)"
    }

    /// Two tiny computations on the GPU: a sum, whose kernel MLX builds at run
    /// time, and an argmax, whose kernel comes from mlx.metallib like those of
    /// the local model. A metallib MLX can't use ends the process, which fails
    /// the smoke test as well.
    static func mlxProblem() -> String? {
        let sum = MLXArray([1, 2, 3] as [Float]).sum().item(Float.self)
        guard sum == 6 else { return "1 + 2 + 3 gave \(sum)" }
        let largest = MLXArray([1, 3, 2] as [Float]).argMax().item(Int.self)
        return largest == 1 ? nil : "argmax of [1, 3, 2] gave \(largest)"
    }
}
