import Foundation
import Accelerate

/// Быстрый анализатор спектра на базе Accelerate / vDSP.
/// Возвращает магнитуды в `size/2` точках (от 0 до Найквиста).
final class FFTProcessor {
    let size: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]

    init?(size: Int) {
        guard size >= 8, (size & (size - 1)) == 0 else { return nil }

        self.size = size

        // log2(size) для преобразования Фурье
        var k: vDSP_Length = 0
        var s = size
        while s > 1 { s >>= 1; k += 1 }
        self.log2n = k

        guard let setup = vDSP_create_fftsetup(k, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup

        var win = [Float](repeating: 0, count: size)
        vDSP_hann_window(&win, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = win

        self.windowed = [Float](repeating: 0, count: size)
        self.realp = [Float](repeating: 0, count: size / 2)
        self.imagp = [Float](repeating: 0, count: size / 2)
        self.mags = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Вход: массив `size` отсчётов (окно). Выход: `size/2` магнитуд в дБ.
    func magnitudesDB(_ input: [Float]) -> [Float] {
        let m = linearMagnitudes(input)
        let n = size
        var out = [Float](repeating: -160, count: n / 2)
        let scale = Float(2.0) / Float(n)      // нормировка преобразования zrip
        let floorValue: Float = 1e-7
        for i in 0..<(n / 2) {
            out[i] = 20.0 * log10f(Swift.max(m[i] * scale, floorValue))
        }
        return out
    }

    /// Вход: массив `size` отсчётов. Выход: `size/2` линейных магнитуд.
    /// Абсолютный масштаб здесь не нормируется — подходит для отношений
    /// (например, гармонико-перкуссионного разделения и поиска тонов).
    func magnitudesLinear(_ input: [Float]) -> [Float] {
        linearMagnitudes(input)
    }

    private func linearMagnitudes(_ input: [Float]) -> [Float] {
        let n = size
        precondition(input.count == n, "FFTProcessor: ожидается \(n) отсчётов")

        var win = windowed
        vDSP_vmul(input, 1, window, 1, &win, 1, vDSP_Length(n))

        var rp = realp
        var ip = imagp
        var m = mags

        rp.withUnsafeMutableBufferPointer { rpBuf in
            ip.withUnsafeMutableBufferPointer { ipBuf in
                var split = DSPSplitComplex(realp: rpBuf.baseAddress!, imagp: ipBuf.baseAddress!)
                win.withUnsafeBufferPointer { winBuf in
                    winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &m, 1, vDSP_Length(n / 2))
            }
        }
        return m
    }
}
