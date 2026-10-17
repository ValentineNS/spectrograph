import Foundation
import AVFoundation

/// Запись моно-PCM в WAV-файл (16 бит).
enum WavWriter {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let frameCount = samples.count
        let dataBytes = frameCount * 2
        let sr = UInt32(Swift.max(1, sampleRate.rounded()))

        var data = Data(capacity: 44 + dataBytes)
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)               // PCM
        appendUInt16(1)               // моно
        appendUInt32(sr)
        appendUInt32(sr * 2)          // байт в секунду
        appendUInt16(2)               // выравнивание блока
        appendUInt16(16)              // бит на отсчёт
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataBytes))

        var pcm = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            var v = samples[i]
            if !v.isFinite { v = 0 }
            if v > 1 { v = 1 } else if v < -1 { v = -1 }
            pcm[i] = Int16(v * 32767.0)
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }

        try data.write(to: url, options: .atomic)
    }
}

/// Проигрывание подготовленного звука из файла.
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(url: URL) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            errorMessage = "Не удалось включить воспроизведение: \(error.localizedDescription)"
            return
        }

        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
            progress = 0
            startTimer()
        } catch {
            errorMessage = "Не удалось воспроизвести звук: \(error.localizedDescription)"
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player else { return }
            let d = p.duration
            self.progress = d > 0 ? Swift.min(1, Swift.max(0, p.currentTime / d)) : 0
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            self?.isPlaying = false
            self?.progress = 1
        }
    }
}
