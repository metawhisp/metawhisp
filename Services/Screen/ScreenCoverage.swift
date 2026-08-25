import Foundation

/// What the screen record actually covers — and, more importantly, what it
/// does not.
///
/// ITER-071 §6: an answer about the day must distinguish observed from
/// unavailable, and may never claim complete coverage when capture was off,
/// the app was not running, or the window belonged to an excluded app. Without
/// this the assistant describes six observed minutes as if they were the
/// afternoon, and the user builds on it.
enum ScreenCoverage {

    /// A stretch with no screen record at all.
    struct Gap: Equatable {
        let from: Date
        let to: Date
        var seconds: TimeInterval { to.timeIntervalSince(from) }
    }

    struct Report: Equatable {
        let windowFrom: Date
        let windowTo: Date
        let observedSeconds: TimeInterval
        let gaps: [Gap]

        var gapSeconds: TimeInterval { gaps.reduce(0) { $0 + $1.seconds } }
        /// Fraction of the asked-about window that has any record behind it.
        var observedFraction: Double {
            let total = windowTo.timeIntervalSince(windowFrom)
            guard total > 0 else { return 0 }
            return max(0, min(1, observedSeconds / total))
        }
    }

    /// A pause shorter than this is someone reading, not a gap in the record.
    /// It matches the capture cadence: a couple of missed polls says nothing.
    static let minimumGapSeconds: TimeInterval = 180

    /// Compute coverage from the moments actually recorded.
    ///
    /// - Parameter samples: timestamps of accepted screen rows inside the
    ///   window, in any order. Each one stands for `cadence` seconds of
    ///   observation — a sample is a moment, and treating it as an instant
    ///   would report a working afternoon as a few seconds of coverage.
    static func report(
        from windowFrom: Date,
        to windowTo: Date,
        samples: [Date],
        cadence: TimeInterval = 30
    ) -> Report {
        guard windowTo > windowFrom else {
            return Report(windowFrom: windowFrom, windowTo: windowTo,
                          observedSeconds: 0, gaps: [])
        }
        let inWindow = samples
            .filter { $0 >= windowFrom && $0 <= windowTo }
            .sorted()
        guard !inWindow.isEmpty else {
            return Report(windowFrom: windowFrom, windowTo: windowTo, observedSeconds: 0,
                          gaps: [Gap(from: windowFrom, to: windowTo)])
        }

        var gaps: [Gap] = []
        var observed: TimeInterval = 0
        var cursor = windowFrom

        for sample in inWindow {
            let covers = max(cursor, sample.addingTimeInterval(-cadence))
            if covers.timeIntervalSince(cursor) >= minimumGapSeconds {
                gaps.append(Gap(from: cursor, to: covers))
            }
            let end = max(cursor, sample)
            observed += end.timeIntervalSince(max(cursor, covers))
            cursor = max(cursor, end)
        }
        if windowTo.timeIntervalSince(cursor) >= minimumGapSeconds {
            gaps.append(Gap(from: cursor, to: windowTo))
        }
        return Report(windowFrom: windowFrom, windowTo: windowTo,
                      observedSeconds: observed, gaps: gaps)
    }

    /// One line for the model, in the answer's own terms. Reason codes and
    /// clock times only — no screen content.
    static func honestyLine(_ report: Report, captureEnabled: Bool,
                            formatter: DateFormatter? = nil) -> String {
        let fmt = formatter ?? {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.timeZone = .current
            return f
        }()
        guard captureEnabled else {
            return "COVERAGE: screen capture is off. Nothing in this period was observed; "
                + "say so plainly and do not describe the period as if it were seen."
        }
        guard !report.gaps.isEmpty else {
            return "COVERAGE: the record is continuous for this period."
        }
        let spans = report.gaps
            .sorted { $0.from < $1.from }
            .prefix(6)
            .map { "\(fmt.string(from: $0.from))–\(fmt.string(from: $0.to))" }
            .joined(separator: ", ")
        let percent = Int((report.observedFraction * 100).rounded())
        return "COVERAGE: about \(percent)% of this period has a screen record. "
            + "Nothing was observed during \(spans)"
            + (report.gaps.count > 6 ? " and \(report.gaps.count - 6) more stretches" : "")
            + ". State these gaps in the answer; never present the period as fully seen."
    }
}
