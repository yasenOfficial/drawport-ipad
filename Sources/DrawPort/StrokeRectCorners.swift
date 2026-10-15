import CoreGraphics

extension CGRect {
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
         CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}
