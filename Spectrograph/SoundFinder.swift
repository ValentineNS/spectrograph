import Foundation
import AVFoundation
import CoreMotion

/// Искатель направления выбранного звука.
///
/// Слушает микрофон, измеряет уровень в заданной полосе частот и по гироскопу
/// запоминает направление, в котором звук был громче всего. Стрелка показывает,
/// куда повернуться, чтобы «навестись» на источник выбранного звука.
final class SoundFinder: ObservableObject {
    @Published var levelDB: Float = -120
    @Published var bestDB: Float = -120
    /// Угол поворота стрелки, градусы (0 — источник по курсу).
    @Published var arrowDegrees: Double = 0
    @Published var isRunning = false
    @Published var hasDirection = false
    @Published var motionAvailable = true
    @Published var errorMessage: String?

    private let bandLow: Double
    private let bandHigh: Double

    private let engine = AVAudioEngine()
    private var fft: FFTProcessor?
    private let fftSize = 1024
    private var sampleRate: Double = 44100
    private var pending: [Float] = []
    private var readIndex = 0
    private var scratch: [Float] = []
    private var lastPublish: CFAbsoluteTime = 0

    private let motion = CMMotionManager()
    private var currentYaw: Double = 0
    private var haveYaw = false
    private var bestYaw: Double = 0

    init(bandLow: Double, bandHigh: Double) {
        self.bandLow = bandLow
        self.bandHigh = bandHigh
        self.fft = FFTProcessor(size: fftSize)
    }

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = "Не удалось включить микрофон: \(error.localizedDescription)"
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
        fft = FFTProcessor(size: fftSize)
        pending.removeAll(keepingCapacity: true)
        readIndex = 0
        lastPublish = 0
        bestDB = -120
        hasDirection = false

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] pcm, _ in
            self?.process(pcm)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Не удалось запустить микрофон: \(error.localizedDescription)"
            return
        }

        if motion.isDeviceMotionAvailable {
            motionAvailable = true
            motion.deviceMotionUpdateInterval = 0.05
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
                guard let self = self, let m = m else { return }
                self.currentYaw = m.attitude.yaw
                self.haveYaw = true
            }
        } else {
            motionAvailable = false
        }

        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        DispatchQueue.main.async { [weak self] in
            self?.levelDB = -120
        }
    }

    // MARK: - Аудиопоток

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

        pending.append(contentsOf: scratch[0..<frames])

        let hop = fftSize / 2
        var latest: Float = -120
        var computed = false
        while pending.count - readIndex >= fftSize {
            let start = readIndex
            let frame = Array(pending[start..<(start + fftSize)])
            let db = fft.magnitudesDB(frame)
            latest = bandLevel(db)
            computed = true
            readIndex += hop
        }
        if readIndex > 65536 {
            pending.removeFirst(readIndex)
            readIndex = 0
        } else if pending.count > 2_000_000 {
            pending.removeAll(keepingCapacity: true)
            readIndex = 0
        }

        guard computed else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPublish >= 0.05 {
            lastPublish = now
            let value = latest
            DispatchQueue.main.async { [weak self] in
                self?.update(level: value)
            }
        }
    }

    private func bandLevel(_ db: [Float]) -> Float {
        guard !db.isEmpty, sampleRate > 0 else { return -120 }
        var b0 = Int(bandLow * Double(fftSize) / sampleRate)
        var b1 = Int(bandHigh * Double(fftSize) / sampleRate)
        if b0 < 1 { b0 = 1 }
        if b0 > db.count - 1 { b0 = db.count - 1 }
        if b1 <= b0 { b1 = b0 + 1 }
        if b1 > db.count { b1 = db.count }
        var mx: Float = -120
        var i = b0
        while i < b1 {
            if db[i] > mx { mx = db[i] }
            i += 1
        }
        return mx
    }

    // MARK: - Направление (главный поток)

    private func update(level: Float) {
        levelDB = level
        if level > bestDB {
            bestDB = level
            bestYaw = currentYaw
            if haveYaw { hasDirection = true }
        } else {
            bestDB = Swift.max(level, bestDB - 0.5)
        }
        if haveYaw && hasDirection {
            var a = bestYaw - currentYaw
            while a > .pi { a -= 2 * .pi }
            while a < -(.pi) { a += 2 * .pi }
            arrowDegrees = a * 180.0 / .pi
        }
    }
}
