import AVFoundation
import Foundation

/// TR-9/TR-10 (ITER-046 D) — streaming mono Float32 resampler backed by
/// `AVAudioConverter`, the same mechanism the mic path uses.
///
/// Replaces the bare per-buffer linear interpolation in the system-audio path,
/// which had two defects that degraded the "Them" stream in every meeting:
/// - TR-9: no low-pass — everything above the output Nyquist (8 kHz) aliased
///   straight into the speech band. `AVAudioConverter` applies a proper
///   anti-aliasing filter before decimation.
/// - TR-10: `Int(frameCount * ratio)` truncated per buffer and the fractional
///   source position never carried over, losing samples at every buffer
///   boundary and drifting mic/system sync on long calls. The converter is
///   created once per capture and keeps that state internally (the input block
///   reports `.noDataNow` between buffers, never `.endOfStream`, so the
///   converter stays primed for the next buffer).
///
/// NOT thread-safe — call from a single serial queue (the SCStream audio queue).
final class StreamingResampler {

    private let outputRate: Double
    private var converter: AVAudioConverter?
    private var inputRate: Double = 0

    init(outputRate: Double) {
        self.outputRate = outputRate
    }

    /// Resample one mono buffer continuing from the previous one. Returns `[]`
    /// on a converter failure (logged) — the caller just skips the buffer.
    func resample(_ mono: [Float], from sourceRate: Double) -> [Float] {
        guard !mono.isEmpty, sourceRate > 0 else { return [] }
        guard sourceRate != outputRate else { return mono }

        if converter == nil || inputRate != sourceRate {
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
                                            channels: 1, interleaved: false),
                  let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                             channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inFmt, to: outFmt)
            else {
                NSLog("[StreamingResampler] ❌ cannot build converter %.0f→%.0f", sourceRate, outputRate)
                return []
            }
            converter = conv
            inputRate = sourceRate
        }
        guard let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(mono.count))
        else { return [] }

        inBuf.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: mono.count)
        }

        let capacity = AVAudioFrameCount((Double(mono.count) * outputRate / sourceRate).rounded(.up)) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return []
        }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if fed {
                // .noDataNow (NOT .endOfStream): more audio arrives with the next
                // buffer — ending the stream would flush and reset the converter,
                // losing exactly the cross-buffer continuity TR-10 requires.
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }

        guard status != .error, let ch = outBuf.floatChannelData else {
            NSLog("[StreamingResampler] ❌ convert failed: %@", error?.localizedDescription ?? "unknown")
            return []
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
