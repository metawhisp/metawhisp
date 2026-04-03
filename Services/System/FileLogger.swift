import Foundation

/// Redirects stderr (and thus NSLog) to ~/Library/Logs/MetaWhisp.log.
/// Truncates log file if > 1MB.
enum FileLogger {
    static func setup() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("MetaWhisp.log")

        // Truncate if > 1MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? Int, size > 1_000_000
        {
            try? "".write(to: logFile, atomically: true, encoding: .utf8)
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
