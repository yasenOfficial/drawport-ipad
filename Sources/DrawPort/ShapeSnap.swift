import Foundation
import UIKit
import PencilKit

/// Optional shape mode; never rewrites ordinary pen strokes.
enum ShapeSnap {
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let denominator = dx * dx + dy * dy
        guard denominator > 0 else { return distance(p, a) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / denominator))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0], last = points[points.count - 1]
        let candidate = (1..<(points.count - 1)).map { ($0, segmentDistance(points[$0], first, last)) }
            .max { $0.1 < $1.1 }
        guard let candidate, candidate.1 > tolerance else { return [first, last] }
        let left = simplified(Array(points[...candidate.0]), tolerance: tolerance)
        let right = simplified(Array(points[candidate.0...]), tolerance: tolerance)
        return left + right.dropFirst()
    }

    private static func sampled(_ vertices: [CGPoint], closed: Bool) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        let sequence = closed ? vertices + [vertices[0]] : vertices
        var result = [sequence[0]]
        for i in 1..<sequence.count {
            let a = sequence[i - 1], b = sequence[i]
            let steps = max(1, min(64, Int(ceil(distance(a, b) / 5))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        return result
    }

    /// Returns nil for short taps, tiny gestures or ambiguous handwriting.
    static func recognized(_ stroke: PKStroke) -> PKStroke? {
        let originals = Array(stroke.path)
        guard (5...4096).contains(originals.count) else { return nil }
        let points = originals.map(\.location)
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX, height = maxY - minY
        let diagonal = hypot(width, height)
        guard diagonal > 28 else { return nil }
        let start = points[0], end = points[points.count - 1]
        let closed = distance(start, end) < max(23, diagonal * 0.18)
        let shapePoints: [CGPoint]
        if !closed {
            let deviation = points.map { segmentDistance($0, start, end) }.max() ?? 0
            if distance(start, end) > 28 && deviation < max(9, diagonal * 0.06) {
                shapePoints = sampled([start, end], closed: false)
            } else {
                // Fit an arc through the start, midpoint and end. For an S-curve
                // keep the original geometry and smooth gently instead.
                let middle = points[points.count / 2]
                let control = CGPoint(x: 2 * middle.x - (start.x + end.x) / 2,
                                      y: 2 * middle.y - (start.y + end.y) / 2)
                let thirds = [points[points.count / 3], points[points.count * 2 / 3]]
                let signs = thirds.map { (end.x - start.x) * ($0.y - start.y) - (end.y - start.y) * ($0.x - start.x) }
                let isSCurve = signs[0] * signs[1] < 0 && thirds.allSatisfy { segmentDistance($0, start, end) > diagonal * 0.07 }
                if !isSCurve && distance(start, end) > 30 && segmentDistance(middle, start, end) > max(9, diagonal * 0.06) {
                    shapePoints = (0...64).map { index in
                        let t = CGFloat(index) / 64, u = 1 - t
                        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
                    }
                } else {
                    shapePoints = points.indices.map { index in
                        let a = points[max(0, index - 1)], b = points[index], c = points[min(index + 1, points.count - 1)]
                        return CGPoint(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4)
                    }
                }
            }
        } else {
            guard width > 25, height > 25 else { return nil }
            var loop = points
            loop.append(start)
            var vertices = simplified(loop, tolerance: max(11, diagonal * 0.075))
            if vertices.count > 2 && distance(vertices[0], vertices[vertices.count - 1]) < max(23, diagonal * 0.18) {
                vertices.removeLast()
            }
            if vertices.count == 3 || vertices.count == 4 {
                shapePoints = sampled(vertices, closed: true) // triangle or rectangle/square
            } else {
                // Many short corners around a roughly elliptical loop.
                let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
                let radiusX = width / 2, radiusY = height / 2
                let error = points.map { abs(hypot(($0.x - center.x) / radiusX, ($0.y - center.y) / radiusY) - 1) }
                    .reduce(0, +) / CGFloat(points.count)
                guard error < 0.3 else { return nil }
                shapePoints = (0...72).map { index in
                    let angle = CGFloat(index) * 2 * .pi / 72
                    return CGPoint(x: center.x + radiusX * cos(angle), y: center.y + radiusY * sin(angle))
                }
            }
        }
        guard shapePoints.count >= 2 else { return nil }
        let reference = originals[0]
        let duration = max(originals.last?.timeOffset ?? 0.1, 0.1)
        let controls = shapePoints.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: duration * Double(index) / Double(shapePoints.count - 1),
                size: reference.size, opacity: reference.opacity, force: reference.force,
                azimuth: reference.azimuth, altitude: reference.altitude,
                secondaryScale: reference.secondaryScale)
        }
        return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: controls,
            creationDate: stroke.path.creationDate), transform: stroke.transform,
            mask: stroke.mask, randomSeed: stroke.randomSeed)
    }
}
