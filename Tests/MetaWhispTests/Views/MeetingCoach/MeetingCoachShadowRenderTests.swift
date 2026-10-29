import AppKit
import Metal
import QuartzCore
import XCTest
@testable import MetaWhisp

extension MeetingCoachRenderTests {
    func testSurfaceShadowsStayInsideNonInteractiveInsets() async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
            action: nil, blocks: [.headline("The next step is ready.")], createdAt: Date(timeIntervalSince1970: 0)))
        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) })
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(250))
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let answer = try XCTUnwrap(controller.answerPanel)
        let capsuleShadow = try XCTUnwrap(controller.capsuleShadowPanel)
        let answerShadow = try XCTUnwrap(controller.answerShadowPanel)
        let interactiveFrames = [capsule.frame, answer.frame]
        XCTAssertEqual(capsule.frame.size, NSSize(width: 168, height: 34))
        XCTAssertEqual(answer.frame.width, 392)
        XCTAssertEqual(capsule.frame.minY - answer.frame.maxY, 8)

        for (surface, shadow) in [(capsule, capsuleShadow), (answer, answerShadow)] {
            XCTAssertTrue(shadow.ignoresMouseEvents)
            XCTAssertTrue(shadow.parent === surface)
            let view = try XCTUnwrap(shadow.contentView as? CardShadowView)
            let pixels = try meetingCoachShadowBitmap(view)
            let silhouetteRect = surface.frame.offsetBy(dx: -shadow.frame.minX, dy: -shadow.frame.minY)
            XCTAssertGreaterThan(silhouetteRect.minX, 0)
            XCTAssertGreaterThan(silhouetteRect.minY, 0)
            XCTAssertLessThan(silhouetteRect.maxX, view.bounds.width)
            XCTAssertLessThan(silhouetteRect.maxY, view.bounds.height)
            let silhouette = CGPath(roundedRect: silhouetteRect, cornerWidth: view.cornerRadius,
                                    cornerHeight: view.cornerRadius, transform: nil)
            var haloPixels = 0
            var outerEdgeAlpha: CGFloat = 0
            var alphaMass: CGFloat = 0, weightedRow: CGFloat = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    let alpha = try XCTUnwrap(pixels.colorAt(x: x, y: y)).alphaComponent
                    if !silhouette.contains(point), alpha > 0.01 { haloPixels += 1 }
                    alphaMass += alpha
                    weightedRow += alpha * CGFloat(y)
                    if x == 0 || y == 0 || x == pixels.pixelsWide - 1 || y == pixels.pixelsHigh - 1 {
                        outerEdgeAlpha = max(outerEdgeAlpha, alpha)
                    }
                }
            }
            XCTAssertGreaterThan(haloPixels, 100, "Each real shadow window must render a halo outside its material shape.")
            XCTAssertLessThanOrEqual(outerEdgeAlpha, 0.01, "The shadow must fade inside its clear inset without a clipped edge.")
            XCTAssertGreaterThan(weightedRow / max(alphaMass, 0.001), CGFloat(pixels.pixelsHigh) / 2,
                                 "The rendered shadow must fall below the surface.")
            XCTAssertLessThan(try XCTUnwrap(pixels.colorAt(x: Int(silhouetteRect.midX),
                                                          y: Int(silhouetteRect.midY))).alphaComponent, 0.01,
                              "The shadow must not tint the glass interior.")
            for point in [NSPoint(x: surface.frame.minX - 1, y: surface.frame.midY),
                          NSPoint(x: surface.frame.maxX + 1, y: surface.frame.midY)] {
                XCTAssertFalse(interactiveFrames.contains { $0.contains(point) }, "The shadow sides are click-through.")
            }
            XCTAssertFalse(surface.isVisible)
            XCTAssertFalse(shadow.isVisible)
        }
        let gap = NSRect(x: min(capsule.frame.minX, answer.frame.minX), y: answer.frame.maxY,
                         width: max(capsule.frame.width, answer.frame.width), height: 8)
        XCTAssertFalse(interactiveFrames.contains { $0.intersects(gap) }, "No interactive window covers the gap.")
        XCTAssertEqual([capsule.frame, answer.frame], interactiveFrames, "Rendering must not change the hit areas.")
    }
}

/// AppKit caching and CALayer.render(in:) omit layer shadows. CARenderer renders
/// the real layer tree to a private Metal texture without ordering any window.
@MainActor
func meetingCoachShadowBitmap(_ view: CardShadowView) throws -> NSBitmapImageRep {
    view.layout()
    view.layer?.layoutIfNeeded()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
    renderer.layer = try XCTUnwrap(view.layer)
    renderer.bounds = view.bounds
    CATransaction.flush()
    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(view.bounds)
    renderer.render()
    renderer.endFrame()
    let fence = try XCTUnwrap(queue.makeCommandBuffer())
    fence.commit()
    fence.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // CARenderer uses bottom-up layer coordinates; CGImage rows are top-down.
    var imageData = Data(capacity: bytes.count)
    for row in (0..<height).reversed() {
        imageData.append(contentsOf: bytes[(row * width * 4)..<((row + 1) * width * 4)])
    }
    let provider = try XCTUnwrap(CGDataProvider(data: imageData as CFData))
    let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    return NSBitmapImageRep(cgImage: image)
}
