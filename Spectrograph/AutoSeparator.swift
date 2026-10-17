import Foundation

/// Автоматически разложенный компонент звука.
struct AutoComponent: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let url: URL
    /// Пересобранный звук компонента (для микширования «играть все»).
    let samples: [Float]
    /// Полоса частот компонента (для искателя направления), Гц.
    let bandLow: Double
    let bandHigh: Double
    /// Превью маски: `previewCols × previewRows`, значения 0…1.
    /// Строка 0 — верх (высокие частоты), столбцы — время слева направо.
    let preview: [Float]
    let previewCols: Int
    let previewRows: Int
}

/// Автоматическое разложение записи на составляющие:
/// отдельные тональные источники, «прочие тона», ударные (транзиенты) и шум/остаток.
///
/// Метод (без нейросетей, чистый DSP):
/// 1. магнитудная спектрограмма (STFT);
/// 2. гармонико-перкуссионное разделение (HPSS) медианными фильтрами
///    → мягкие маски «гармоническое» / «ударное»;
/// 3. поиск основных тонов (гармоническая значимость) в каждом кадре;
/// 4. отслеживание тонов во времени → устойчивые источники;
/// 5. маски компонентов и обратное преобразование (пересборка звука).
enum AutoSeparator {

    /// Прослеженный во времени тональный источник.
    private struct Source {
        var frames: [Int] = []
        var freqs: [Double] = []
        var strengths: [Float] = []
        var lastFreq: Double = 0
        var gap: Int = 0
        var energy: Double = 0
    }

    /// Разбирает запись на составляющие и сохраняет каждую в отдельный WAV.
    static func decompose(samples: [Float],
                          sampleRate: Double,
                          fftSize: Int,
                          totalFrames: Int,
                          maxFrequency: Double) -> [AutoComponent] {
        let hop = Swift.max(1, fftSize / 2)
        let bins = fftSize / 2
        guard totalFrames > 4, bins > 4, sampleRate > 0 else { return [] }
        let outLen = (totalFrames - 1) * hop + fftSize
        guard samples.count >= outLen else { return [] }
        guard let fft = FFTProcessor(size: fftSize) else { return [] }

        let hWindow = 15
        let pWindow = 15
        let maxSources = 5
        let minSourceFrames = 6
        let maxGap = 5
        let harmonics = 12

        let nyquist = sampleRate / 2
        let fmax = Swift.max(1, Swift.min(maxFrequency, nyquist))
        let f0min = 70.0
        let f0max = Swift.max(f0min + 10, Swift.min(fmax * 0.7, 4000.0))
        let binPerHz = Double(fftSize) / sampleRate
        let b0min = Swift.max(1, Int((f0min * binPerHz).rounded(.down)))
        let b0max = Swift.min(bins - 1, Int((f0max * binPerHz).rounded(.up)))
        let maxBin = Swift.min(bins - 1, Int((fmax * binPerHz).rounded(.up)))
        guard b0max > b0min, maxBin > b0min else { return [] }

        let total = totalFrames * bins

        // MARK: 1. Магнитудная спектрограмма
        var mag = [Float](repeating: 0, count: total)
        var maxMag: Float = 0
        for f in 0..<totalFrames {
            let start = f * hop
            let frame = Array(samples[start..<(start + fftSize)])
            let m = fft.magnitudesLinear(frame)
            let base = f * bins
            for k in 0..<bins {
                let v = m[k]
                mag[base + k] = v
                if v > maxMag { maxMag = v }
            }
        }
        guard maxMag > 0 else { return [] }

        // MARK: 2. HPSS — медианные фильтры и мягкая маска гармонического
        var colBuf = [Float](repeating: 0, count: hWindow)
        var rowBuf = [Float](repeating: 0, count: pWindow)

        func median(_ buf: inout [Float], _ n: Int) -> Float {
            if n <= 0 { return 0 }
            var i = 1
            while i < n {
                let v = buf[i]
                var j = i - 1
                while j >= 0 && buf[j] > v {
                    buf[j + 1] = buf[j]
                    j -= 1
                }
                buf[j + 1] = v
                i += 1
            }
            return buf[n / 2]
        }

        var Mh = [Float](repeating: 0, count: total)
        do {
            let hHalf = hWindow / 2
            for f in 0..<totalFrames {
                let a = Swift.max(0, f - hHalf)
                let b = Swift.min(totalFrames - 1, f + hHalf)
                let base = f * bins
                for k in 0..<bins {
                    var n = 0
                    var i = a
                    while i <= b {
                        colBuf[n] = mag[i * bins + k]
                        n += 1
                        i += 1
                    }
                    let hv = median(&colBuf, n)
                    let pa = Swift.max(0, k - pWindow / 2)
                    let pb = Swift.min(bins - 1, k + pWindow / 2)
                    var pn = 0
                    var j = pa
                    while j <= pb {
                        rowBuf[pn] = mag[base + j]
                        pn += 1
                        j += 1
                    }
                    let pv = median(&rowBuf, pn)
                    let hh = hv * hv
                    let pp = pv * pv
                    let d = hh + pp
                    Mh[base + k] = d > 1e-12 ? hh / d : 0.5
                }
            }
        }

        // MARK: 3. Поиск основных тонов по гармонической значимости
        var candidatesByFrame = [[(bin: Int, strength: Float)]](repeating: [], count: totalFrames)
        let floorMag = maxMag * 0.02

        for f in 0..<totalFrames {
            let base = f * bins
            var sal = [Float](repeating: 0, count: b0max + 1)
            var maxSal: Float = 0
            var b = b0min
            while b <= b0max {
                var s: Float = 0
                var n = 1
                while n <= harmonics {
                    let hb = n * b
                    if hb > maxBin { break }
                    var v = mag[base + hb] * Mh[base + hb]
                    if hb + 1 <= maxBin {
                        let w = mag[base + hb + 1] * Mh[base + hb + 1]
                        if w > v { v = w }
                    }
                    if hb - 1 >= 0 {
                        let w = mag[base + hb - 1] * Mh[base + hb - 1]
                        if w > v { v = w }
                    }
                    s += v
                    n += 1
                }
                sal[b] = s
                if s > maxSal { maxSal = s }
                b += 1
            }
            if maxSal < floorMag { continue }

            let thr = maxSal * 0.12
            var peaks: [(bin: Int, strength: Float)] = []
            var pk = Swift.max(b0min, 1)
            while pk <= b0max - 1 {
                if sal[pk] > sal[pk - 1] && sal[pk] >= sal[pk + 1] && sal[pk] > thr {
                    peaks.append((pk, sal[pk]))
                }
                pk += 1
            }
            peaks.sort { $0.strength > $1.strength }

            var chosen: [(bin: Int, strength: Float)] = []
            for p in peaks {
                let fp = Double(p.bin) / binPerHz
                var ok = true
                for c in chosen {
                    let fc = Double(c.bin) / binPerHz
                    if abs(fp - fc) < Swift.max(30.0, 0.06 * fc) { ok = false; break }
                }
                if ok { chosen.append(p) }
                if chosen.count >= 6 { break }
            }
            candidatesByFrame[f] = chosen
        }

        // MARK: 4. Отслеживание тонов во времени
        var active: [Source] = []
        var finished: [Source] = []

        for f in 0..<totalFrames {
            var cands = candidatesByFrame[f]
            if !cands.isEmpty {
                for si in active.indices {
                    var best = -1
                    var bestRel = Double.infinity
                    for ci in cands.indices {
                        let fc = Double(cands[ci].bin) / binPerHz
                        let rel = abs(fc - active[si].lastFreq) / Swift.max(1.0, active[si].lastFreq)
                        if rel < bestRel { bestRel = rel; best = ci }
                    }
                    if best >= 0 && bestRel < 0.06 {
                        let c = cands[best]
                        let fr = Double(c.bin) / binPerHz
                        active[si].frames.append(f)
                        active[si].freqs.append(fr)
                        active[si].strengths.append(c.strength)
                        active[si].lastFreq = fr
                        active[si].energy += Double(c.strength)
                        active[si].gap = 0
                        cands.remove(at: best)
                    } else {
                        active[si].gap += 1
                    }
                }
            } else {
                for si in active.indices { active[si].gap += 1 }
            }

            for c in cands {
                var s = Source()
                let fr = Double(c.bin) / binPerHz
                s.frames = [f]
                s.freqs = [fr]
                s.strengths = [c.strength]
                s.lastFreq = fr
                s.energy = Double(c.strength)
                active.append(s)
            }

            var still: [Source] = []
            still.reserveCapacity(active.count)
            for s in active {
                if s.gap > maxGap { finished.append(s) } else { still.append(s) }
            }
            active = still
        }
        finished.append(contentsOf: active)

        // MARK: 5. Отбор устойчивых источников
        func medianValue(_ values: [Float]) -> Float {
            if values.isEmpty { return 0 }
            var v = values
            v.sort()
            return v[v.count / 2]
        }

        var good = finished.filter { $0.frames.count >= minSourceFrames }
        good = good.filter { medianValue($0.strengths) > maxMag * 0.01 }
        good.sort { $0.energy > $1.energy }

        // Добавляет «бугры» вокруг гармоник источника в массив-накопитель.
        func addBumps(into arr: inout [Float], source: Source) {
            let nFrames = source.frames.count
            var idx = 0
            while idx < nFrames {
                let f = source.frames[idx]
                if f < 0 || f >= totalFrames { idx += 1; continue }
                let f0 = source.freqs[idx]
                let base = f * bins
                var n = 1
                while n <= harmonics {
                    let hf = f0 * Double(n)
                    if hf > fmax { break }
                    let center = hf * binPerHz
                    let half = Swift.max(2.0, center * 0.015)
                    let lo = Swift.max(1, Int((center - half).rounded(.down)))
                    let hi = Swift.min(bins - 1, Int((center + half).rounded(.up)))
                    if lo <= hi {
                        var k = lo
                        while k <= hi {
                            let d = abs(Double(k) - center) / half
                            let w = Float(Swift.max(0.0, 1.0 - d))
                            if w > 0 { arr[base + k] += w }
                            k += 1
                        }
                    }
                    n += 1
                }
                idx += 1
            }
        }

        var bumpAll = [Float](repeating: 0, count: total)
        var bumpOther = [Float](repeating: 0, count: total)
        for (index, source) in good.enumerated() {
            if index < maxSources {
                addBumps(into: &bumpAll, source: source)
            } else {
                addBumps(into: &bumpAll, source: source)
                addBumps(into: &bumpOther, source: source)
            }
        }

        // MARK: 6. Пересборка компонентов
        guard let processor = SpectralProcessor(fftSize: fftSize) else { return [] }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var result: [AutoComponent] = []
        var fileIndex = 0

        func rms(_ v: [Float]) -> Float {
            if v.isEmpty { return 0 }
            var s: Float = 0
            for x in v { s += x * x }
            return (s / Float(v.count)).squareRoot()
        }

        // Превью маски: 0…1, строка 0 — верх (высокие частоты).
        let previewCols = Swift.max(1, Swift.min(totalFrames, 200))
        let previewRows = 64

        func makePreview(_ mask: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: previewCols * previewRows)
            let binCount = Swift.max(1, maxBin)
            for py in 0..<previewRows {
                let fHi = Double(previewRows - py) / Double(previewRows)
                let fLo = Double(previewRows - py - 1) / Double(previewRows)
                var k0 = Int(fLo * Double(binCount))
                var k1 = Int(fHi * Double(binCount))
                if k0 < 0 { k0 = 0 }
                if k1 <= k0 { k1 = k0 + 1 }
                if k1 > bins { k1 = bins }
                for px in 0..<previewCols {
                    let f0 = px * totalFrames / previewCols
                    let f1 = Swift.max(f0 + 1, (px + 1) * totalFrames / previewCols)
                    var mx: Float = 0
                    for f in f0..<f1 {
                        let base = f * bins
                        for k in k0..<k1 {
                            let v = mask[base + k]
                            if v > mx { mx = v }
                        }
                    }
                    out[py * previewCols + px] = mx
                }
            }
            return out
        }

        func emit(title: String, detail: String, mask: [Float],
                  bandLow: Double, bandHigh: Double) {
            guard mask.count == total else { return }
            let rendered = processor.renderWithMask(samples: samples, totalFrames: totalFrames, mask: mask)
            guard !rendered.isEmpty, rms(rendered) > 1e-4 else { return }
            let url = folder.appendingPathComponent("comp-\(fileIndex).wav")
            do {
                try WavWriter.write(samples: rendered, sampleRate: sampleRate, to: url)
                fileIndex += 1
                result.append(AutoComponent(title: title,
                                            detail: detail,
                                            url: url,
                                            samples: rendered,
                                            bandLow: bandLow,
                                            bandHigh: bandHigh,
                                            preview: makePreview(mask),
                                            previewCols: previewCols,
                                            previewRows: previewRows))
            } catch {
                // пропускаем неудачный компонент
            }
        }

        func frequencyTitle(_ hz: Double) -> String {
            if hz >= 1000 {
                return String(format: "%.2f кГц", hz / 1000)
            }
            return String(format: "%.0f Гц", hz)
        }

        func combine(_ src: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: total)
            var i = 0
            while i < total {
                let w = bumpAll[i]
                if w > 1e-6 {
                    let cover = Swift.min(w, 1)
                    out[i] = Mh[i] * cover * (src[i] / w)
                }
                i += 1
            }
            return out
        }

        // Отдельные тона
        for index in 0..<Swift.min(maxSources, good.count) {
            let source = good[index]
            var srcBump = [Float](repeating: 0, count: total)
            addBumps(into: &srcBump, source: source)
            let mask = combine(srcBump)

            var freqs = source.freqs
            freqs.sort()
            let medianFreq = freqs.isEmpty ? 0 : freqs[freqs.count / 2]
            let seconds = Double(source.frames.count) * Double(hop) / sampleRate
            emit(title: "Тон \(index + 1) · \(frequencyTitle(medianFreq))",
                 detail: String(format: "%.1f с", seconds),
                 mask: mask,
                 bandLow: Swift.max(40, medianFreq * 0.8),
                 bandHigh: medianFreq * 1.25)
        }

        // Прочие тона
        if good.count > maxSources {
            emit(title: "Прочие тона",
                 detail: "источников: \(good.count - maxSources)",
                 mask: combine(bumpOther),
                 bandLow: 0,
                 bandHigh: fmax)
        }

        // Ударные (транзиенты): всё, что не гармоническое
        do {
            var mask = [Float](repeating: 0, count: total)
            var i = 0
            while i < total {
                mask[i] = 1 - Mh[i]
                i += 1
            }
            emit(title: "Ударные (стук, щелчки)", detail: "", mask: mask, bandLow: 0, bandHigh: fmax)
        }

        // Шум / остаток: гармоническое, не объяснённое тонами
        do {
            var mask = [Float](repeating: 0, count: total)
            var i = 0
            while i < total {
                let cover = Swift.min(bumpAll[i], 1)
                mask[i] = Mh[i] * (1 - cover)
                i += 1
            }
            emit(title: "Шум / остаток", detail: "", mask: mask, bandLow: 0, bandHigh: fmax)
        }

        return result
    }
}
