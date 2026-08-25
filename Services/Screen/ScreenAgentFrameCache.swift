import AppKit
import CoreGraphics
import CryptoKit
import Foundation

/// The one frame vision is allowed to look at, and nowhere else it may live.
///
/// The privacy contract is structural, not promised: capacity is exactly one
/// frame, it exists only in memory, it is keyed to the exact captured context,
/// and it dies on replacement, on expiry, on purge, and with the process.
/// There is no code path from here to SwiftData, to a file, or to a log —
/// which is the only kind of "we never store screenshots" worth saying.
@MainActor
final class ScreenAgentFrameCache {

    struct CachedFrame {
        let contextID: UUID
        let jpeg: Data
        /// The capture epoch this frame belongs to. ITER-069 §4 — the vision
        /// request carries it, the response must echo it.
        let generation: Int
        /// SHA-256 of the exact bytes sent, computed once at store time.
        let contentHash: String
        let capturedAt: Date
    }

    private var frame: CachedFrame?

    /// A frame older than this describes a screen the user has left; the
    /// vision budget is for the present.
    static let maxAgeSeconds: TimeInterval = ScreenAgentTimingPolicy.maxResultAgeSeconds

    /// Keep exactly this frame, forgetting any previous one.
    func store(contextID: UUID, jpeg: Data, generation: Int, capturedAt: Date = Date()) {
        frame = CachedFrame(contextID: contextID, jpeg: jpeg, generation: generation,
                            contentHash: Self.contentHash(of: jpeg), capturedAt: capturedAt)
    }

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The frame for this exact context, if it is still fresh. A mismatched
    /// context or an expired frame returns nothing — a vision call about the
    /// wrong screen is worse than no vision call.
    func take(matching contextID: UUID, at now: Date = Date()) -> CachedFrame? {
        guard let frame,
              frame.contextID == contextID,
              now.timeIntervalSince(frame.capturedAt) <= Self.maxAgeSeconds
        else { return nil }
        return frame
    }

    /// Purge, consent revoked, feature off, lock, quit.
    func invalidateAll() {
        frame = nil
    }
}

/// Downscaling for the wire: long edge capped, JPEG, size-bounded.
enum ScreenFrameEncoder {

    static let maxLongEdge: CGFloat = 1280
    static let maxPayloadBytes = 1_000_000

    /// nil when the frame cannot be brought under the bounds — in which case
    /// no image is sent at all, rather than a bigger one.
    static func downscaledJPEG(from image: CGImage) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxLongEdge / max(width, height))
        let target = NSSize(width: floor(width * scale), height: floor(height * scale))

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.interpolationQuality = .medium
        NSGraphicsContext.current?.cgContext.draw(
            image, in: CGRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        // Step quality down until the payload fits; refuse rather than exceed.
        for quality in [0.7, 0.5, 0.35] {
            if let data = rep.representation(using: .jpeg,
                                             properties: [.compressionFactor: quality]),
               data.count <= maxPayloadBytes {
                return data
            }
        }
        return nil
    }
}
