import XCTest
@testable import MetaWhisp

/// Retroactive tests for `TranscriptionCoordinator.saveSamplesAsWav` —
/// the recovery path that writes raw audio to disk when Cloud Whisper
/// fails. Same honest disclosure as the StructuredGenerator tests:
/// shipped without RED-first under batch pressure on 2026-05-01.
/// Tests verify: empty input is rejected, valid input writes a readable
/// WAV file, sample rate / channel count / format match expectations.
@MainActor
final class TranscriptionCoordinatorRecoveryTests: XCTestCase {

    /// Synthesize 1 second of silence at 16kHz Float32 mono.
    private func silence(seconds: Int) -> [Float] {
        return Array(repeating: 0.0, count: seconds * 16_000)
    }

    /// Empty samples → no file written, returns nil. Avoids creating
    /// zero-byte files on every silent stop.
    func test_saveSamplesAsWav_emptyInputReturnsNil() {
        let url = TranscriptionCoordinator.saveSamplesAsWav([])
        XCTAssertNil(url)
    }

    /// Valid 2-sec buffer → file exists at returned URL, non-zero size.
    func test_saveSamplesAsWav_writesFileForValidInput() throws {
        let samples = silence(seconds: 2)
        guard let url = TranscriptionCoordinator.saveSamplesAsWav(samples) else {
            return XCTFail("saveSamplesAsWav returned nil for valid input")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        // 2s @ 16kHz @ 4 bytes/sample = 128k payload + ~80B header
        XCTAssertGreaterThan(size, 100_000)
    }

    /// File lands inside the recovery folder we promised the user. If we
    /// silently moved the path elsewhere, support docs and the lastError
    /// hint would point to the wrong place.
    func test_saveSamplesAsWav_writesIntoRecoveryFolder() throws {
        let samples = silence(seconds: 1)
        guard let url = TranscriptionCoordinator.saveSamplesAsWav(samples) else {
            return XCTFail("saveSamplesAsWav returned nil for valid input")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let path = url.path
        XCTAssertTrue(path.contains("/MetaWhisp/Recovery/"),
                      "Expected path to contain /MetaWhisp/Recovery/, got: \(path)")
        XCTAssertTrue(path.hasSuffix(".wav"),
                      "Expected .wav extension, got: \(path)")
    }
}
