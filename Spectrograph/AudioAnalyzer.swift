import Foundation
import AVFoundation
import Accelerate
import Combine

/// Захват звука с микрофона, БПФ и обновление «водопада».
final class AudioAnalyzer: ObservableObject {
    @Published var isRunning = false
    @Published var levelDB: Float = -120
    @Published var peakDB: Float = -120
    @Published var peakFrequency: Double = 0
    @Published var sampleRate: Double = 44100
    @Published var errorMessage: String?
    @Published var frozenFrames: Int = 0

    let buffer = WaterfallBuffer()
    /// Записанный звук текущего сеанса (для спектрального анализа).
    let store = AudioStore()

    /// Число видимых столбцов спектрограммы — задаётся из интерфейса.
    var visibleColumns: Int = 0

    private let settings: SpectrogramSettings
    private let engine = AVAudioEngine()
    private var fft: FFTProcessor?
    private var fftSize: Int

    private var pending: [Float] = []
    private var readIndex = 0
    private var scratch: [Float] = []
    private var latestDB: [Float]?
    private var lastPublish: CFAbsoluteTime = 0
    private var cancellables = Set<AnyCancellable>()

    init(settings: SpectrogramSettings) {
        self.settings = settings
        self.fftSize = settings.fftSize
        self.fft = FFTProcessor(size: settings.fftSize)

        settings.$fftSize
            .removeDuplicates()
            .sink { [weak self] size in
                self?.applyFFTSize(size)
            }
            .store(in: &cancellables)
    }

    // MARK: - Управление

    func start() {
        guard !isRunning else { return }
        requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.startEngine()
                } else {
                    self.errorMessage = "Нет доступа к микрофону. Разрешите его в «Настройки → Конфиденциальность → Микрофон»."
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        // Оставляем ровно то, что видно на спектрограмме.
        store.freeze(visibleColumns: visibleColumns)
        frozenFrames = store.totalFrames
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        DispatchQueue.main.async { [weak self] in
            self?.levelDB = -120
            self?.peakDB = -120
            self?.peakFrequency = 0
        }
    }

    private func applyFFTSize(_ size: Int) {
        guard size != fftSize else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        fftSize = size
        fft = FFTProcessor(size: size)
        pending.removeAll(keepingCapacity: true)
        readIndex = 0
        latestDB = nil
        if wasRunning { start() }
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: completion)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(completion)
        }
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = "Не удалось активировать микрофон: \(error.localizedDescription)"
            return
        }

        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = input.inputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "Микрофон недоступен."
            return
        }

        sampleRate = format.sampleRate
        fftSize = settings.fftSize
        fft = FFTProcessor(size: fftSize)
        pending.removeAll(keepingCapacity: true)
        readIndex = 0
        latestDB = nil
        store.reset(sampleRate: format.sampleRate, fftSize: fftSize)
        frozenFrames = 0

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            self?.process(pcm)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Не удалось запустить запись: \(error.localizedDescription)"
        }
    }

    // MARK: - Обработка (аудиопоток)

    private func process(_ pcm: AVAudioPCMBuffer) {
        guard let fft = fft else { return }
        let frames = Int(pcm.frameLength)
        guard frames > 0, let channels = pcm.floatChannelData else { return }
        let channelCount = Int(pcm.format.channelCount)
        let left = channels[0]

        if scratch.count < frames {
            scratch = [Float](repeating: 0, count: frames)
        }
        if channelCount >= 2 {
            let right = channels[1]
            for i in 0..<frames {
                scratch[i] = 0.5 * (left[i] + right[i])
            }
        } else {
            for i in 0..<frames {
                scratch[i] = left[i]
            }
        }

        var rms: Float = 0
        vDSP_rmsqv(scratch, 1, &rms, vDSP_Length(frames))
        let level = 20 * log10f(max(rms, 1e-7))

        pending.append(contentsOf: scratch[0..<frames])
        store.append(scratch[0..<frames])

        let hop = max(1, fftSize / 2)
        while pending.count - readIndex >= fftSize {
            let start = readIndex
            let frame = Array(pending[start..<(start + fftSize)])
            let db = fft.magnitudesDB(frame)
            buffer.append(db)
            latestDB = db
            readIndex += hop
        }

        if readIndex > 65536 {
            pending.removeFirst(readIndex)
            readIndex = 0
        } else if pending.count > 4_000_000 {
            pending.removeAll(keepingCapacity: true)
            readIndex = 0
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPublish >= 0.15 {
            lastPublish = now
            var peakValue: Float = -120
            var peakFreq: Double = 0
            if let db = latestDB, db.count > 1, sampleRate > 0 {
                let nyquist = sampleRate / 2
                let fmax = min(settings.maxFrequency, nyquist)
                var maxBin = Int(fmax * Double(fftSize) / sampleRate)
                if maxBin < 1 { maxBin = 1 }
                if maxBin > db.count - 1 { maxBin = db.count - 1 }
                var best = 1
                var bestValue: Float = -1000
                var i = 1
                while i <= maxBin {
                    if db[i] > bestValue {
                        bestValue = db[i]
                        best = i
                    }
                    i += 1
                }
                peakValue = bestValue
                peakFreq = Double(best) * sampleRate / Double(fftSize)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.levelDB = level
                self.peakDB = peakValue
                self.peakFrequency = peakFreq
            }
        }
    }
}
