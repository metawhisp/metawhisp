import CoreGraphics
import Foundation
import Vision

/// Reading text off a captured frame, away from the main thread.
///
/// `VNImageRequestHandler.perform` is synchronous, and it was being called from
/// inside `ScreenContextService`, which is `@MainActor`. Accurate recognition
/// over a full-screen image is not quick, so every capture stalled whatever the
/// user was doing — a background feature making the foreground stutter.
///
/// The flat string is assembled exactly as before, in the order Vision returns
/// observations, so existing consumers and the stored history see byte-identical
/// text. Bounds come along beside it for reasoning that needs to know where
/// something sat on screen: today the prompts ask which chat bubble is on the
/// right and the model has no way to know, because the geometry was thrown away
/// here.
enum ScreenOCR {

    /// One recognized run of text and where it was.
    ///
    /// Coordinates are Vision's normalized image space — origin bottom-left,
    /// 0...1 on both axes — so they stay meaningful whatever the frame was
    /// scaled to.
    struct Block: Codable, Equatable {
        let text: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let confidence: Double
    }

    struct Reading: Equatable {
        let text: String
        let blocks: [Block]

        static let empty = Reading(text: "", blocks: [])
    }

    /// The flat text, joined the way it always has been: in observation order,
    /// one line per block. Changing this ordering would silently rewrite every
    /// stored transcript of the screen, so it stays as it was.
    static func assemble(_ blocks: [Block]) -> String {
        blocks.map(\.text).joined(separator: "\n")
    }

    static func recognize(_ image: CGImage) async -> Reading {
        await withCheckedContinuation { continuation in
            // Off the main thread. This is the whole point of the file.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: perform(on: image))
            }
        }
    }

    private static func perform(on image: CGImage) -> Reading {
        var blocks: [Block] = []
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            blocks = observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return Block(
                    text: candidate.string,
                    x: Double(box.origin.x),
                    y: Double(box.origin.y),
                    width: Double(box.width),
                    height: Double(box.height),
                    confidence: Double(candidate.confidence)
                )
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "ru-RU", "de-DE", "fr-FR", "es-ES"]
        request.automaticallyDetectsLanguage = true

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("[ScreenOCR] failed: %@", error.localizedDescription)
            return .empty
        }
        return Reading(text: assemble(blocks), blocks: blocks)
    }
}
