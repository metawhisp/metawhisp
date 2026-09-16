import Foundation

/// Redirects stderr (and thus NSLog) to ~/Library/Logs/MetaWhisp.log.
///
/// A full log is ROTATED, not emptied. Emptying it destroyed the evidence of
/// the run that filled it — and the run that fills a megabyte is the one worth
/// reading (2026-09-16: two days of a wedged capture path were erased by the
/// restart meant to diagnose it). One previous generation is kept as
/// `MetaWhisp.log.1`.
enum FileLogger {

    /// Above this, the live log starts a new generation.
    static let rotateAboveBytes = 1_000_000

    enum Plan: Equatable { case append, rotate }

    static func plan(size: Int) -> Plan {
        size > rotateAboveBytes ? .rotate : .append
    }

    /// Move the live log aside, replacing the one older generation.
    static func rotate(_ log: URL, to previous: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: log, to: previous)
    }

    static func setup() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("MetaWhisp.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? Int,
           plan(size: size) == .rotate
        {
            rotate(logFile, to: logsDir.appendingPathComponent("MetaWhisp.log.1"))
        }

        if let fh = FileHandle(forWritingAtPath: logFile.path) {
            fh.seekToEndOfFile()
            let dupFd = dup(fileno(stderr))
            dup2(fh.fileDescriptor, fileno(stderr))
            _ = dupFd // keep original stderr alive
        } else {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            if let fh = FileHandle(forWritingAtPath: logFile.path) {
                dup2(fh.fileDescriptor, fileno(stderr))
            }
        }
    }
}
