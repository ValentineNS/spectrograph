import Foundation
import Combine

/// Цветовая схема спектрограммы.
enum ColorMap: String, CaseIterable, Identifiable {
    case turbo
    case viridis
    case inferno
    case grayscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turbo: return "Turbo"
        case .viridis: return "Viridis"
        case .inferno: return "Inferno"
        case .grayscale: return "Оттенки серого"
        }
    }

    /// Контрольные точки цвета (0…255) для линейной интерполяции.
    private var stops: [(UInt8, UInt8, UInt8)] {
        switch self {
        case .turbo:
            return [
                (48, 18, 59), (65, 69, 171), (70, 134, 251), (57, 183, 225),
                (41, 213, 175), (48, 231, 113), (109, 240, 66), (180, 235, 46),
                (234, 208, 45), (253, 166, 42), (245, 110, 35), (205, 55, 13),
                (122, 4, 3)
            ]
        case .viridis:
            return [
                (68, 1, 84), (72, 40, 120), (62, 74, 137), (49, 104, 142),
                (38, 130, 142), (31, 158, 137), (53, 183, 121), (109, 205, 89),
                (180, 222, 44), (225, 228, 26), (253, 231, 37)
            ]
        case .inferno:
            return [
                (0, 0, 4), (22, 11, 57), (66, 10, 104), (106, 23, 110),
                (147, 38, 103), (188, 55, 84), (221, 81, 58), (243, 120, 25),
                (252, 165, 10), (246, 215, 70), (252, 255, 164)
            ]
        case .grayscale:
            var s: [(UInt8, UInt8, UInt8)] = []
            s.reserveCapacity(256)
            for i in 0..<256 {
                let v = UInt8(i)
                s.append((v, v, v))
            }
            return s
        }
    }

    /// Палитра из 256 цветов RGBA (4 байта на цвет) для быстрой отрисовки.
    func makeLUT() -> [UInt8] {
        let points = stops
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        guard !points.isEmpty else { return lut }

        if points.count == 1 {
            let c = points[0]
            for i in 0..<256 {
                lut[i * 4 + 0] = c.0
                lut[i * 4 + 1] = c.1
                lut[i * 4 + 2] = c.2
                lut[i * 4 + 3] = 255
            }
            return lut
        }

        let last = points.count - 1
        for i in 0..<256 {
            let t = Float(i) / 255.0 * Float(last)
            var i0 = Int(t)
            if i0 < 0 { i0 = 0 }
            if i0 > last { i0 = last }
            let i1 = min(i0 + 1, last)
            let f = t - Float(i0)
            let a = points[i0]
            let b = points[i1]
            let r = Float(a.0) + (Float(b.0) - Float(a.0)) * f
            let g = Float(a.1) + (Float(b.1) - Float(a.1)) * f
            let bl = Float(a.2) + (Float(b.2) - Float(a.2)) * f
            lut[i * 4 + 0] = UInt8(max(0, min(255, r.rounded())))
            lut[i * 4 + 1] = UInt8(max(0, min(255, g.rounded())))
            lut[i * 4 + 2] = UInt8(max(0, min(255, bl.rounded())))
            lut[i * 4 + 3] = 255
        }
        return lut
    }
}

/// Настройки спектрографа (наблюдаемый объект для SwiftUI).
final class SpectrogramSettings: ObservableObject {
    static let fftSizes: [Int] = [512, 1024, 2048, 4096]
    static let maxFrequencies: [Double] = [2000, 4000, 8000, 16000]
    static let dynamicRanges: [Double] = [40, 60, 80, 100]

    @Published var fftSize: Int = 1024
    @Published var maxFrequency: Double = 8000
    @Published var logScale: Bool = false
    @Published var dynamicRange: Double = 80
    @Published var topDB: Double = -10
    @Published var colorMap: ColorMap = .turbo

    /// Нижняя граница отображаемых уровней, дБ.
    var minDB: Double { topDB - dynamicRange }
}

/// Расчёт отметок для осей.
enum AxisTicks {
    /// Отметки частоты. `fraction` = 0 внизу (0 Гц), 1 вверху (макс. частота).
    static func frequency(maxFrequency: Double, logScale: Bool) -> [(fraction: Double, label: String)] {
        guard maxFrequency > 0 else { return [] }

        if logScale {
            let fmin = max(20.0, maxFrequency / 1000.0)
            let lmin = log10(fmin)
            let lmax = log10(maxFrequency)
            let span = max(1e-6, lmax - lmin)
            let candidates: [Double] = [20, 30, 50, 70, 100, 150, 200, 300, 500, 700,
                                        1000, 1500, 2000, 3000, 5000, 7000, 10000, 15000, 20000]
            var out: [(fraction: Double, label: String)] = []
            for f in candidates where f >= fmin * 0.999 && f <= maxFrequency * 1.001 {
                let frac = (log10(f) - lmin) / span
                out.append((fraction: frac, label: formatFrequency(f)))
            }
            return out
        }

        let step = niceStep(maxFrequency / 5.0)
        var out: [(fraction: Double, label: String)] = []
        var f = 0.0
        var guardCount = 0
        while f <= maxFrequency + step * 0.001 && guardCount < 40 {
            out.append((fraction: f / maxFrequency, label: formatFrequency(f)))
            f += step
            guardCount += 1
        }
        return out
    }

    /// Отметки времени. `fraction` = 0 слева (самое старое), 1 справа (сейчас).
    static func time(history: Double) -> [(fraction: Double, label: String)] {
        guard history > 0 else { return [] }
        let step = niceStep(history / 5.0)
        var out: [(fraction: Double, label: String)] = []
        var t = 0.0
        var guardCount = 0
        while t <= history + step * 0.001 && guardCount < 40 {
            let frac = 1.0 - t / history
            out.append((fraction: frac, label: t < 0.5 ? "0" : String(format: "-%.0f", t)))
            t += step
            guardCount += 1
        }
        return out
    }

    /// Частота по вертикальной доле (0 — низ, 1 — верх) для текущей шкалы.
    static func frequency(forFraction fraction: Double, maxFrequency: Double, logScale: Bool) -> Double {
        guard maxFrequency > 0 else { return 0 }
        let f = min(max(fraction, 0), 1)
        if logScale {
            let fmin = max(20.0, maxFrequency / 1000.0)
            let lmin = log10(fmin)
            let lmax = log10(maxFrequency)
            return pow(10, lmin + (lmax - lmin) * f)
        }
        return maxFrequency * f
    }

    /// «Красивый» шаг сетки (1, 2, 5, 10, …).
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        let m = raw / base
        let nice: Double
        if m < 1.5 { nice = 1 }
        else if m < 3 { nice = 2 }
        else if m < 7 { nice = 5 }
        else { nice = 10 }
        return nice * base
    }

    /// Короткая подпись частоты для оси (например «8к», «500»).
    static func formatFrequency(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            if abs(k.rounded() - k) < 0.05 {
                return String(format: "%.0fк", k)
            }
            return String(format: "%.1fк", k)
        }
        return String(format: "%.0f", f)
    }

    /// Полная подпись частоты (например «8 кГц», «500 Гц»).
    static func formatFrequencyFull(_ f: Double) -> String {
        if f >= 1000 {
            let k = f / 1000
            if abs(k.rounded() - k) < 0.05 {
                return String(format: "%.0f кГц", k)
            }
            return String(format: "%.1f кГц", k)
        }
        return String(format: "%.0f Гц", f)
    }
}
