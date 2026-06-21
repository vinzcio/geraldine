import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk). Returns one rect per
/// value, in the same order, packed to keep cells close to square.
enum Treemap {
    static func layout(values: [CGFloat], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else {
            return Array(repeating: .zero, count: values.count)
        }
        let scale = (rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var result = [CGRect](repeating: .zero, count: areas.count)
        var remaining = rect
        var i = 0
        while i < areas.count {
            let side = min(remaining.width, remaining.height)
            var rowCount = 1
            while i + rowCount < areas.count {
                let current = Array(areas[i ..< i + rowCount])
                let extended = Array(areas[i ..< i + rowCount + 1])
                if worst(extended, side) <= worst(current, side) { rowCount += 1 } else { break }
            }
            let row = Array(areas[i ..< i + rowCount])
            let rowSum = row.reduce(0, +)
            let thickness = rowSum / side

            if remaining.width >= remaining.height {
                var y = remaining.minY
                for (k, area) in row.enumerated() {
                    let h = area / thickness
                    result[i + k] = CGRect(x: remaining.minX, y: y, width: thickness, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: remaining.width - thickness, height: remaining.height)
            } else {
                var x = remaining.minX
                for (k, area) in row.enumerated() {
                    let w = area / thickness
                    result[i + k] = CGRect(x: x, y: remaining.minY, width: w, height: thickness)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: remaining.height - thickness)
            }
            i += rowCount
        }
        return result
    }

    private static func worst(_ row: [CGFloat], _ side: CGFloat) -> CGFloat {
        let sum = row.reduce(0, +)
        guard let maxA = row.max(), let minA = row.min(), sum > 0, minA > 0 else {
            return .greatestFiniteMagnitude
        }
        let s2 = sum * sum, side2 = side * side
        return Swift.max(side2 * maxA / s2, s2 / (side2 * minA))
    }
}
