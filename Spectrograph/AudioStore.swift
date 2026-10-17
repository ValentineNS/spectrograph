import Foundation

/// Накапливает записанный звук для последующего спектрального анализа.
/// Потокобезопасен: запись идёт из аудиопотока, чтение — из главного.
final class AudioStore {
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var sampleRate: Double = 44100
    private(set) var fftSize: Int = 1024
    /// Сколько столбцов спектрограммы было видно в момент остановки записи.
    private(set) var visibleColumns: Int = 0

    private let maxSamples: Int

    init(maxSeconds: Double = 120) {
        self.maxSamples = Int(maxSeconds * 48000)
    }

    /// Шаг между кадрами БПФ (в отсчётах).
    var hop: Int { Swift.max(1, fftSize / 2) }

    /// Число полных кадров БПФ, доступных в буфере.
    var totalFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return framesLocked()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return samples.isEmpty
    }

    private func framesLocked() -> Int {
        let n = samples.count
        guard n >= fftSize else { return 0 }
        return (n - fftSize) / hop + 1
    }

    func reset(sampleRate: Double, fftSize: Int) {
        lock.lock(); defer { lock.unlock() }
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.visibleColumns = 0
        samples.removeAll(keepingCapacity: true)
    }

    func append<S: Sequence>(_ chunk: S) where S.Element == Float {
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: chunk)
        if samples.count > maxSamples {
            // Скользящий буфер: отбрасываем самую старую часть, выравнивая по кадрам.
            var drop = samples.count - maxSamples / 2
            drop -= drop % hop
            if drop > 0 && drop < samples.count {
                samples.removeFirst(drop)
            }
        }
    }

    /// Оставляет в буфере только последние `visibleColumns` кадров — ровно то,
    /// что видно на спектрограмме. Так выделения на экране однозначно
    /// соответствуют звуку.
    func freeze(visibleColumns: Int) {
        lock.lock(); defer { lock.unlock() }
        let total = framesLocked()
        var cols = visibleColumns
        if cols <= 0 { cols = total }
        self.visibleColumns = cols
        let keep = Swift.min(cols, total)
        guard keep > 0, keep < total else { return }
        let start = (total - keep) * hop
        if start > 0 && start < samples.count {
            samples.removeFirst(start)
        }
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var meta: (sampleRate: Double, fftSize: Int, visibleColumns: Int, totalFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sampleRate, fftSize, visibleColumns, framesLocked())
    }
}
