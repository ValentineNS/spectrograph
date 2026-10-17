import Foundation
import Accelerate

/// Прямоугольное выделение на спектрограмме. Координаты нормированы 0…1:
/// `x` — время (слева направо), `y` — частота (снизу вверх).
struct SpectralSelection: Identifiable, Equatable {
    let id = UUID()
    var x0: Double
    var x1: Double
    var y0: Double
    var y1: Double

    init(x0: Double, x1: Double, y0: Double, y1: Double) {
        self.x0 = Swift.min(x0, x1)
        self.x1 = Swift.max(x0, x1)
        self.y0 = Swift.min(y0, y1)
        self.y1 = Swift.max(y0, y1)
    }
}

/// Как обрабатывать выделенные области.
enum MaskMode {
    /// Оставить только выделенное.
    case isolate
    /// Убрать выделенное, оставить всё остальное.
    case remove
}

/// Кратковременное преобразование Фурье с маской и обратным перекрытием.
/// Позволяет «вырезать» из звука отдельные составляющие по частоте и времени.
final class SpectralProcessor {
    let fftSize: Int
    let hop: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let inverseScale: Float

    init?(fftSize: Int) {
        guard fftSize >= 16, (fftSize & (fftSize - 1)) == 0 else { return nil }

        self.fftSize = fftSize
        self.hop = fftSize / 2

        var k: vDSP_Length = 0
        var s = fftSize
        while s > 1 { s >>= 1; k += 1 }
        self.log2n = k

        guard let setup = vDSP_create_fftsetup(k, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup

        var win = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&win, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.window = win
        self.inverseScale = SpectralProcessor.calibrate(setup: setup, log2n: k, n: fftSize, window: win)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    // MARK: - Калибровка нормировки обратного БПФ

    /// Прямое и обратное zrip-преобразование связаны постоянным множителем.
    /// Измеряем его один раз на тестовом сигнале, чтобы не зависеть от соглашений vDSP.
    private static func calibrate(setup: FFTSetup, log2n: vDSP_Length, n: Int, window: [Float]) -> Float {
        let bins = n / 2
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var out = [Float](repeating: 0, count: n)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                window.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { ob in
                    ob.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                        vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(bins))
                    }
                }
            }
        }

        var num: Float = 0
        var den: Float = 0
        for i in 0..<n {
            num += out[i] * window[i]
            den += window[i] * window[i]
        }
        guard den > 0, num != 0 else { return 1 }
        return 1 / (num / den)
    }

    // MARK: - Отображение координат

    private func frameForX(_ x: Double, totalFrames: Int, visibleColumns: Int) -> Double {
        let cols = Swift.max(1, visibleColumns)
        let cx = Swift.min(Swift.max(x, 0), 1)
        return Double(totalFrames - cols) + cx * Double(cols - 1)
    }

    // MARK: - Основная обработка

    /// Пересобирает звук, оставляя или убирая выделенные области.
    func render(samples: [Float],
                sampleRate: Double,
                totalFrames: Int,
                visibleColumns: Int,
                selections: [SpectralSelection],
                maxFrequency: Double,
                logScale: Bool,
                mode: MaskMode) -> [Float] {
        let n = fftSize
        let bins = n / 2
        let outLen = (totalFrames - 1) * hop + n
        guard totalFrames > 0, bins > 0, sampleRate > 0, outLen > 0,
              samples.count >= outLen else { return [] }

        struct Region {
            var f0: Int
            var f1: Int
            var bins: [Bool]
        }

        let nyquist = sampleRate / 2
        let fmax = Swift.max(1, Swift.min(maxFrequency, nyquist))

        var regions: [Region] = []
        regions.reserveCapacity(selections.count)
        for sel in selections {
            let fa = frameForX(sel.x0, totalFrames: totalFrames, visibleColumns: visibleColumns)
            let fb = frameForX(sel.x1, totalFrames: totalFrames, visibleColumns: visibleColumns)
            var f0 = Int(fa.rounded(.down))
            var f1 = Int(fb.rounded(.up))
            if f0 < 0 { f0 = 0 }
            if f1 > totalFrames - 1 { f1 = totalFrames - 1 }
            if f1 < f0 { continue }

            let hz0 = AxisTicks.frequency(forFraction: sel.y0, maxFrequency: fmax, logScale: logScale)
            let hz1 = AxisTicks.frequency(forFraction: sel.y1, maxFrequency: fmax, logScale: logScale)
            var b0 = Int((hz0 * Double(n) / sampleRate).rounded(.down))
            var b1 = Int((hz1 * Double(n) / sampleRate).rounded(.up))
            if b0 < 0 { b0 = 0 }
            if b0 > bins - 1 { b0 = bins - 1 }
            if b1 <= b0 { b1 = b0 + 1 }
            if b1 > bins { b1 = bins }

            var flags = [Bool](repeating: false, count: bins)
            for k in b0..<b1 { flags[k] = true }
            regions.append(Region(f0: f0, f1: f1, bins: flags))
        }

        let realp = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let imagp = UnsafeMutablePointer<Float>.allocate(capacity: bins)
        let frameBuf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: outLen)
        let norm = UnsafeMutablePointer<Float>.allocate(capacity: outLen)
        defer {
            realp.deallocate()
            imagp.deallocate()
            frameBuf.deallocate()
            out.deallocate()
            norm.deallocate()
        }
        realp.initialize(repeating: 0, count: bins)
        imagp.initialize(repeating: 0, count: bins)
        frameBuf.initialize(repeating: 0, count: n)
        out.initialize(repeating: 0, count: outLen)
        norm.initialize(repeating: 0, count: outLen)

        var wsq = [Float](repeating: 0, count: n)
        vDSP_vmul(window, 1, window, 1, &wsq, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        let isolate = (mode == .isolate)
        let win = window

        samples.withUnsafeBufferPointer { sb in
            guard let base = sb.baseAddress else { return }
            for f in 0..<totalFrames {
                let start = f * hop
                vDSP_vmul(base + start, 1, win, 1, frameBuf, 1, vDSP_Length(n))

                frameBuf.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                for k in 0..<bins {
                    var inside = false
                    for r in regions {
                        if f >= r.f0 && f <= r.f1 && r.bins[k] {
                            inside = true
                            break
                        }
                    }
                    let keep: Float = (isolate == inside) ? 1 : 0
                    realp[k] *= keep
                    imagp[k] *= keep
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                frameBuf.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                    vDSP_ztoc(&split, 1, cp, 2, vDSP_Length(bins))
                }

                for i in 0..<n {
                    let o = start + i
                    if o < outLen {
                        out[o] += frameBuf[i] * inverseScale * win[i]
                        norm[o] += wsq[i]
                    }
                }
            }
        }

        for i in 0..<outLen {
            let d = norm[i]
            if d > 1e-6 { out[i] /= d }
        }

        return Array(UnsafeBufferPointer(start: out, count: outLen))
    }
}
