import AppKit
import CoreGraphics
import Foundation
@testable import SnapCore

/// Opaque, deterministic multicolor tiles avoid benchmarking only an empty,
/// transparent image. Still synthetic: these are not screenshot measurements.
private func patternedImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in stride(from: 0, to: height, by: 16) {
        for x in stride(from: 0, to: width, by: 16) {
            let seed = (x * 31 + y * 17) % 251
            context.setFillColor(CGColor(red: CGFloat(seed) / 255, green: CGFloat((seed * 7) % 251) / 255,
                                         blue: CGFloat((seed * 13) % 251) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
        }
    }
    return context.makeImage()!
}

/// 20 each: arrows, rectangles, opaque blocks, Unicode text (10 callouts), and
/// numbered markers, including double-digit labels. Geometry scales with input.
private func mixedAnnotations(width: Int, height: Int) -> [AnnotationValue] {
    let sx = CGFloat(width) / 800
    let sy = CGFloat(height) / 600
    var number = 0
    return (0..<100).map { index in
        let x = CGFloat(12 + index % 10 * 78) * sx
        let y = CGFloat(12 + index / 10 * 58) * sy
        switch index % 5 {
        case 0: return .arrow(ArrowAnnotation(start: CGPoint(x: x, y: y), end: CGPoint(x: x + 45 * sx, y: y + 35 * sy)))
        case 1: return .rectangle(RectangleAnnotation(rect: CGRect(x: x, y: y, width: 50 * sx, height: 35 * sy)))
        case 2: return .privacyBlock(PrivacyBlockAnnotation(rect: CGRect(x: x, y: y, width: 45 * sx, height: 30 * sy)))
        case 3: return .text(TextAnnotation(origin: CGPoint(x: x, y: y), text: "世界 \(index)\ne\u{301}", width: 58 * sx,
            style: TextStyle(presentation: (index / 10).isMultiple(of: 2) ? .plain : .callout,
                             color: AnnotationColor.allCases[index % 6], fontSize: 14 * sx)))
        default:
            number += 1
            return .number(NumberAnnotation(center: CGPoint(x: x + 20 * sx, y: y + 20 * sy), number: number,
                                            diameter: 28 * sx, fontSize: 18 * sx))
        }
    }
}

private func percentile95(_ values: [Double]) -> Double {
    values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
}

@MainActor
func registerAnnotationPerformanceTests() {
    for (width, height) in [(800, 600), (3840, 2160)] {
        test("phase6 \(width)x\(height) 100 mixed annotations pipeline percentiles") {
            let base = patternedImage(width: width, height: height)
            let annotations = mixedAnnotations(width: width, height: height)
            try expectEqual(annotations.count, 100)
            let pipeline = AnnotationRenderPipeline(clipboardService: ClipboardService())
            var total: [Double] = [], render: [Double] = [], encode: [Double] = [], publish: [Double] = []
            for iteration in 0..<33 {
                pipeline.scheduleRender(baseImage: base, annotations: annotations)
                let published = await pipeline.awaitPendingRender()
                try expect(published, "performance sample failed to publish")
                if iteration < 3 { continue }
                let durations = CaptureSignposts.shared.lastDurationsMilliseconds
                total.append(durations[.annotationMouseUpToClipboard]!)
                render.append(durations[.annotationRender]!)
                encode.append(durations[.pngEncode]!)
                publish.append(durations[.clipboardPublication]!)
            }
            let p95 = percentile95(total)
            print(String(format: "probe phase6 %dx%d 100 mixed (30 samples, 3 warmups): total p95 %.2f ms, render %.2f ms, encode %.2f ms, publication %.2f ms; ordinary <50ms target %@",
                width, height, p95, percentile95(render), percentile95(encode), percentile95(publish),
                width == 800 ? (p95 < 50 ? "MET" : "MISSED") : "not applicable"))
            // Timing misses are reported, not hidden as functional failures or
            // mistaken for physical input-to-display or real capture timings.
            try expectEqual(total.count, 30)
            try expect(!pipeline.isWorking && !pipeline.hasPendingSnapshot)
            let png = NSPasteboard.general.data(forType: .png)!
            let image = try decodedClipboardImage(png)
            try expectEqual(image.width, width)
            try expectEqual(image.height, height)
        }

        test("phase6 \(width)x\(height) 100 mixed annotations drag and CPU redraw percentiles") {
            let base = patternedImage(width: width, height: height)
            let canvas = AnnotationCanvasView(baseImage: base)
            let viewHeight = CGFloat(height) * 800 / CGFloat(width)
            canvas.frame = CGRect(x: 0, y: 0, width: 800, height: viewHeight)
            canvas.setAnnotations(mixedAnnotations(width: width, height: height).map { Annotation(value: $0) })
            defer { canvas.releaseResources() }
            let context = CGContext(data: nil, width: 800, height: Int(viewHeight), bitsPerComponent: 8,
                bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: 0, y: viewHeight)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.currentTool = .arrow
            canvas.mouseDown(with: workflowMouse(.leftMouseDown, CGPoint(x: 30, y: 30), canvas: canvas))
            var handler: [Double] = [], feedback: [Double] = []
            var commits = 0
            canvas.onCommit = { _ in commits += 1 }
            for iteration in 0..<103 {
                let point = CGPoint(x: CGFloat(width) * CGFloat(40 + iteration % 50) / 100,
                                    y: CGFloat(height) * 0.8)
                let event = workflowMouse(.leftMouseDragged, point, canvas: canvas)
                let start = ContinuousClock.now
                canvas.mouseDragged(with: event)
                let handlerMs = milliseconds(from: start.duration(to: .now))
                canvas.draw(canvas.bounds)
                let feedbackMs = milliseconds(from: start.duration(to: .now))
                if iteration >= 3 { handler.append(handlerMs); feedback.append(feedbackMs) }
            }
            try expectEqual(commits, 0)
            try expectEqual(handler.count, 100)
            print(String(format: "probe phase6 %dx%d drag (100 samples, 800pt canvas): handler p95 %.2f ms, handler+full CPU draw p95 %.2f ms; <16.67ms CPU proxy %@ (display latency unmeasured)",
                width, height, percentile95(handler), percentile95(feedback),
                percentile95(feedback) < 1000 / 60 ? "MET" : "MISSED"))
            canvas.cancelGesture()
        }
    }
}
