import UIKit
import CoreGraphics

/// Пиксельный буфер «водопада»: столбцы спектра копятся справа налево.
/// Потокобезопасен: запись идёт из аудиопотока, чтение — из главного.
final class WaterfallBuffer {
    private let lock = NSLock()

    private var width = 0
    private var height = 0
    private var bytesPerRow = 0
    private var pixelData: UnsafeMutablePointer<UInt8>?
    private var context: CGContext?

    private var lut = [UInt8](repeating: 0, count: 256 * 4)
    private var rowStart: [Int] = []
    private var rowEnd: [Int] = []

    private var minDB: Float = -90
    private var maxDB: Float = -10
    private var dirty = false

    /// Сколько столбцов в секунду добавляется (для оси времени).
    private(set) var columnRate: Double = 0

    deinit {
        pixelData?.deallocate()
    }

    /// Настраивает размер картинки и пересчитывает палитру и разметку частот.
    func configure(width newWidth: Int,
                   height newHeight: Int,
                   fftSize: Int,
                   sampleRate: Double,
                   maxFrequency: Double,
                   logScale: Bool,
                   minDB: Float,
                   maxDB: Float,
                   colorMap: ColorMap) {
        lock.lock()
        defer { lock.unlock() }

        let w = max(1, newWidth)
        let h = max(1, newHeight)

        if context == nil || w != width || h != height {
            width = w
            height = h
            bytesPerRow = w * 4
            pixelData?.deallocate()
            let total = h * bytesPerRow
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
            ptr.initialize(repeating: 0, count: total)
            pixelData = ptr
            let space = CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            context = CGContext(data: ptr,
                                width: w,
                                height: h,
                                bitsPerComponent: 8,
                                bytesPerRow: bytesPerRow,
                                space: space,
                                bitmapInfo: info)
            if let ctx = context {
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
        }

        self.minDB = minDB
        self.maxDB = maxDB
        self.lut = colorMap.makeLUT()

        let nyquist = sampleRate > 0 ? sampleRate / 2 : maxFrequency
        let fmax = max(1, min(maxFrequency, nyquist))
        let binCount = max(1, fftSize / 2)
        let binsPerHz = sampleRate > 0 ? Double(fftSize) / sampleRate : 0

        let logMin = logScale ? max(20.0, fmax / 1000.0) : 0
        let lmin = log10(max(1e-3, logMin))
        let lmax = log10(fmax)

        rowStart = [Int](repeating: 0, count: h)
        rowEnd = [Int](repeating: 1, count: h)

        let denom = Double(max(1, h - 1))
        for r in 0..<h {
            let t0 = Double(r) / denom
            let t1 = Double(min(r + 1, h - 1)) / denom
            let f0: Double
            let f1: Double
            if logScale {
                f0 = pow(10, lmin + (lmax - lmin) * t0)
                f1 = pow(10, lmin + (lmax - lmin) * t1)
            } else {
                f0 = fmax * t0
                f1 = fmax * t1
            }
            var b0 = Int(floor(f0 * binsPerHz))
            var b1 = Int(ceil(f1 * binsPerHz))
            if b0 < 0 { b0 = 0 }
            if b0 > binCount - 1 { b0 = binCount - 1 }
            if b1 <= b0 { b1 = b0 + 1 }
            if b1 > binCount { b1 = binCount }
            rowStart[r] = b0
            rowEnd[r] = b1
        }

        columnRate = sampleRate > 0 ? sampleRate / Double(max(1, fftSize / 2)) : 0
        dirty = true
    }

    /// Добавляет один столбец спектра (`fftSize/2` значений в дБ).
    func append(_ db: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = context, let raw = ctx.data, width > 0, height > 0, !db.isEmpty else { return }
        let data = raw.assumingMemoryBound(to: UInt8.self)
        let bpr = bytesPerRow

        // Сдвигаем всё на один пиксель влево.
        if width > 1 {
            for row in 0..<height {
                let p = data + row * bpr
                memmove(p, p + 4, (width - 1) * 4)
            }
        }

        let x = width - 1
        let span = maxDB - minDB
        let lutLocal = lut
        let count = db.count
        db.withUnsafeBufferPointer { buf in
            guard let bp = buf.baseAddress else { return }
            for row in 0..<height {
                let r = height - 1 - row
                var s = rowStart[r]
                var e = rowEnd[r]
                if s >= count { s = count - 1 }
                if e > count { e = count }
                var v: Float = -1000
                var i = s
                while i < e {
                    if bp[i] > v { v = bp[i] }
                    i += 1
                }
                var norm: Float = span > 0 ? (v - minDB) / span : 0
                if norm < 0 { norm = 0 } else if norm > 1 { norm = 1 }
                let idx = Int(norm * 255)
                let li = idx * 4
                let p = data + row * bpr + x * 4
                p[0] = lutLocal[li]
                p[1] = lutLocal[li + 1]
                p[2] = lutLocal[li + 2]
                p[3] = 255
            }
        }
        dirty = true
    }

    /// Текущая картинка. Возвращает `nil`, если новых столбцов не было.
    func makeImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let ctx = context else { return nil }
        dirty = false
        return ctx.makeImage()
    }

    /// Снимок текущей картинки независимо от флага изменений (для экспорта).
    func snapshot() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return context?.makeImage()
    }

    var pixelWidth: Int {
        lock.lock(); defer { lock.unlock() }
        return width
    }

    var pixelHeight: Int {
        lock.lock(); defer { lock.unlock() }
        return height
    }
}

/// Представление «водопада» с обновлением через CADisplayLink.
final class WaterfallView: UIView {
    let buffer: WaterfallBuffer
    var configProvider: ((Int, Int) -> Void)?
    var onPixelWidth: ((Double) -> Void)?

    private var displayLink: CADisplayLink?
    private var lastWidth = -1
    private var lastHeight = -1

    init(buffer: WaterfallBuffer) {
        self.buffer = buffer
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.backgroundColor = UIColor.black.cgColor
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не поддерживается")
    }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        requestConfigure()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            startDisplayLink()
            requestConfigure()
        }
    }

    func requestConfigure() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0 else { return }
        lastWidth = w
        lastHeight = h
        configProvider?(w, h)
        onPixelWidth?(Double(w))
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(onTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onTick() {
        if let image = buffer.makeImage() {
            layer.contents = image
        }
    }
}
