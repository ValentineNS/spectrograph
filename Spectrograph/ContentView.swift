import Foundation
import SwiftUI
import CoreGraphics

/// Корневое представление приложения.
struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        SpectrographScreen(settings: model.settings, analyzer: model.analyzer)
    }
}

/// Общая модель: настройки и анализатор живут в одном месте.
final class AppModel: ObservableObject {
    let settings: SpectrogramSettings
    let analyzer: AudioAnalyzer

    init() {
        let s = SpectrogramSettings()
        self.settings = s
        self.analyzer = AudioAnalyzer(settings: s)
    }
}

/// Одно активное модальное окно.
private enum ActiveSheet: Identifiable {
    case settings
    case share(URL)
    case auto

    var id: String {
        switch self {
        case .settings: return "settings"
        case .share(let url): return "share-\(url.absoluteString)"
        case .auto: return "auto"
        }
    }
}

struct SpectrographScreen: View {
    @ObservedObject var settings: SpectrogramSettings
    @ObservedObject var analyzer: AudioAnalyzer

    @StateObject private var playback = AudioPlayback()

    @State private var activeSheet: ActiveSheet?
    @State private var pixelWidth: Double = 0

    @State private var selections: [SpectralSelection] = []
    @State private var isProcessing = false

    @State private var autoComponents: [AutoComponent] = []
    @State private var autoSpectrogram: CGImage?
    @State private var autoSampleRate: Double = 44100
    @State private var isAutoProcessing = false

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private var effectiveMaxFrequency: Double {
        let nyq = analyzer.sampleRate > 0 ? analyzer.sampleRate / 2 : settings.maxFrequency
        return max(1, min(settings.maxFrequency, nyq))
    }

    private var columnRate: Double {
        let hop = max(1, settings.fftSize / 2)
        return analyzer.sampleRate > 0 ? analyzer.sampleRate / Double(hop) : 0
    }

    private var historySeconds: Double {
        guard columnRate > 0 else { return 0 }
        return pixelWidth / columnRate
    }

    private var canSelect: Bool {
        !analyzer.isRunning && analyzer.frozenFrames > 0 && !analyzer.store.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            readouts

            HStack(spacing: 0) {
                FrequencyAxisView(maxFrequency: effectiveMaxFrequency, logScale: settings.logScale)
                    .frame(width: 46)

                SpectrogramView(buffer: analyzer.buffer,
                                fftSize: settings.fftSize,
                                sampleRate: analyzer.sampleRate,
                                maxFrequency: settings.maxFrequency,
                                logScale: settings.logScale,
                                minDB: Float(settings.minDB),
                                maxDB: Float(settings.topDB),
                                colorMap: settings.colorMap,
                                onPixelWidth: { width in
                                    pixelWidth = width
                                    analyzer.visibleColumns = Int(width.rounded())
                                })
                    .background(Color.black)
                    .clipped()
                    .overlay(SelectionOverlay(enabled: canSelect, selections: $selections))
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.35), lineWidth: 1))
            }

            TimeAxisView(historySeconds: historySeconds)
                .frame(height: 16)
                .padding(.leading, 46)

            hintRow
            controls
        }
        .padding(8)
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView(settings: settings)
            case .share(let url):
                ShareSheet(items: [url])
            case .auto:
                AutoDecomposeView(components: autoComponents,
                                  spectrogram: autoSpectrogram,
                                  sampleRate: autoSampleRate,
                                  playback: playback)
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { analyzer.errorMessage != nil || playback.errorMessage != nil },
            set: { present in
                if !present {
                    analyzer.errorMessage = nil
                    playback.errorMessage = nil
                }
            }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(analyzer.errorMessage ?? playback.errorMessage ?? "")
        }
    }

    // MARK: - Показания

    private var readouts: some View {
        HStack(alignment: .firstTextBaseline) {
            readout(title: "Уровень", value: levelText)
            Spacer(minLength: 12)
            readout(title: "Пик", value: peakText)
        }
        .frame(maxWidth: .infinity)
    }

    private func readout(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var levelText: String {
        guard analyzer.isRunning else { return "—" }
        return String(format: "%.1f дБFS", analyzer.levelDB)
    }

    private var peakText: String {
        guard analyzer.isRunning, analyzer.peakFrequency > 0 else { return "—" }
        let f = analyzer.peakFrequency
        let fText: String
        if f >= 1000 {
            fText = String(format: "%.2f кГц", f / 1000)
        } else {
            fText = String(format: "%.0f Гц", f)
        }
        return String(format: "%@ · %.0f дБ", fText, analyzer.peakDB)
    }

    // MARK: - Подсказка и ход обработки

    @ViewBuilder
    private var hintRow: some View {
        if isAutoProcessing {
            HStack(spacing: 6) {
                ProgressView()
                Text("Раскладываю звук на составляющие…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else if isProcessing {
            HStack(spacing: 6) {
                ProgressView()
                Text("Обработка звука…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else if analyzer.isRunning {
            Text("Остановите запись (Стоп), чтобы выделять области на спектрограмме.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if canSelect {
            Text("Проведите по спектрограмме, чтобы выделить составляющую, или нажмите «Авто» для автоматического разложения. Выделений: \(selections.count).")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Нажмите «Старт», чтобы записать звук.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Кнопки

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if analyzer.isRunning {
                        analyzer.stop()
                    } else {
                        selections.removeAll()
                        playback.stop()
                        analyzer.start()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: analyzer.isRunning ? "stop.fill" : "mic.fill")
                        Text(analyzer.isRunning ? "Стоп" : "Старт")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(analyzer.isRunning ? .red : .accentColor)

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 30)
                }
                .buttonStyle(.bordered)

                Menu {
                    Button("PNG спектрограммы") { exportPNG() }
                    Divider()
                    Button("WAV — выделенное") { exportAudio(.isolate) }
                        .disabled(selections.isEmpty)
                    Button("WAV — остальное") { exportAudio(.remove) }
                        .disabled(selections.isEmpty)
                    Button("WAV — оригинал") { exportAudio(nil) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 30)
                }
                .buttonStyle(.bordered)
            }

            if canSelect {
                HStack(spacing: 6) {
                    Button {
                        runAuto()
                    } label: {
                        Label("Авто", systemImage: "sparkles")
                    }
                    .disabled(isProcessing || isAutoProcessing)

                    Button {
                        play(.isolate)
                    } label: {
                        Label("Выдел.", systemImage: "play.circle")
                    }
                    .disabled(selections.isEmpty || isProcessing)

                    Button {
                        play(.remove)
                    } label: {
                        Label("Остал.", systemImage: "play.circle")
                    }
                    .disabled(selections.isEmpty || isProcessing)

                    Menu {
                        Button("Прослушать оригинал") { play(nil) }
                        Divider()
                        if selections.isEmpty {
                            Text("Нет выделений")
                        } else {
                            ForEach(Array(selections.indices), id: \.self) { index in
                                Button("Компонента \(index + 1)") { playSelection(index) }
                            }
                            Divider()
                            Button("Очистить всё", role: .destructive) {
                                selections.removeAll()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isProcessing)
                }
                .font(.system(size: 13))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if playback.isPlaying {
                Button {
                    playback.stop()
                } label: {
                    Label("Остановить звук", systemImage: "stop.circle")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    // MARK: - Автоматическое разложение

    private func runAuto() {
        guard !analyzer.isRunning else {
            analyzer.errorMessage = "Сначала остановите запись."
            return
        }
        let meta = analyzer.store.meta
        guard meta.totalFrames > 4 else {
            analyzer.errorMessage = "Нет записанного звука."
            return
        }

        let samples = analyzer.store.snapshot()
        let sampleRate = meta.sampleRate
        let fftSize = meta.fftSize
        let frames = meta.totalFrames
        let maxFreq = min(effectiveMaxFrequency, sampleRate / 2)

        playback.stop()
        isAutoProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let components = AutoSeparator.decompose(samples: samples,
                                                     sampleRate: sampleRate,
                                                     fftSize: fftSize,
                                                     totalFrames: frames,
                                                     maxFrequency: maxFreq)
            DispatchQueue.main.async {
                self.isAutoProcessing = false
                if components.isEmpty {
                    self.analyzer.errorMessage = "Не удалось разложить звук на составляющие."
                } else {
                    self.autoComponents = components
                    self.autoSpectrogram = self.analyzer.buffer.snapshot()
                    self.autoSampleRate = sampleRate
                    self.activeSheet = .auto
                }
            }
        }
    }

    // MARK: - Обработка и воспроизведение

    private func play(_ mode: MaskMode?) {
        processAudio(mode: mode, selections: selections) { url in
            if let url = url { playback.play(url: url) }
        }
    }

    private func playSelection(_ index: Int) {
        guard index >= 0, index < selections.count else { return }
        let single = [selections[index]]
        processAudio(mode: .isolate, selections: single) { url in
            if let url = url { playback.play(url: url) }
        }
    }

    private func exportAudio(_ mode: MaskMode?) {
        processAudio(mode: mode, selections: selections) { url in
            if let url = url {
                activeSheet = .share(url)
            }
        }
    }

    private func processAudio(mode: MaskMode?,
                              selections sels: [SpectralSelection],
                              completion: @escaping (URL?) -> Void) {
        guard !analyzer.isRunning else {
            analyzer.errorMessage = "Сначала остановите запись."
            return
        }
        if mode != nil && sels.isEmpty {
            analyzer.errorMessage = "Сначала выделите область на спектрограмме."
            return
        }

        let meta = analyzer.store.meta
        guard meta.totalFrames > 0 else {
            analyzer.errorMessage = "Нет записанного звука."
            return
        }

        let samples = analyzer.store.snapshot()
        let sampleRate = meta.sampleRate
        let maxFreq = min(effectiveMaxFrequency, sampleRate / 2)
        let logScale = settings.logScale
        let fftSize = meta.fftSize

        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            var output = samples
            if let mode = mode {
                if let processor = SpectralProcessor(fftSize: fftSize) {
                    output = processor.render(samples: samples,
                                              sampleRate: sampleRate,
                                              totalFrames: meta.totalFrames,
                                              visibleColumns: meta.visibleColumns,
                                              selections: sels,
                                              maxFrequency: maxFreq,
                                              logScale: logScale,
                                              mode: mode)
                }
            }

            var url: URL?
            if !output.isEmpty {
                let name = "spectro-\(Self.fileFormatter.string(from: Date())).wav"
                let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                do {
                    try WavWriter.write(samples: output, sampleRate: sampleRate, to: target)
                    url = target
                } catch {
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.analyzer.errorMessage = "Не удалось сохранить звук: \(error.localizedDescription)"
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self.isProcessing = false
                if url == nil {
                    self.analyzer.errorMessage = "Не удалось обработать звук."
                }
                completion(url)
            }
        }
    }

    // MARK: - Экспорт PNG

    private var captionText: String {
        "БПФ \(settings.fftSize) · 0–\(Int(effectiveMaxFrequency)) Гц · \(Int(settings.dynamicRange)) дБ · \(settings.colorMap.title)"
    }

    private func exportPNG() {
        guard let cg = analyzer.buffer.snapshot() else {
            analyzer.errorMessage = "Нет данных для экспорта."
            return
        }
        let image = SpectrogramExporter.render(spectrogram: cg,
                                               maxFrequency: effectiveMaxFrequency,
                                               logScale: settings.logScale,
                                               historySeconds: max(0, historySeconds),
                                               caption: captionText)
        guard let data = image.pngData() else {
            analyzer.errorMessage = "Не удалось закодировать PNG."
            return
        }
        let name = "spectrogram-\(Self.fileFormatter.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            activeSheet = .share(url)
        } catch {
            analyzer.errorMessage = "Не удалось сохранить PNG: \(error.localizedDescription)"
        }
    }
}

// MARK: - Окно «Составляющие звука»

struct AutoDecomposeView: View {
    let allComponents: [AutoComponent]
    let spectrogram: CGImage?
    let sampleRate: Double
    @ObservedObject var playback: AudioPlayback

    @Environment(\.dismiss) private var dismiss
    @State private var items: [AutoComponent]

    @State private var playingID: UUID?
    @State private var playingAll = false

    @State private var overlayImage: CGImage?
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var finderComponent: AutoComponent?

    private static let palette: [(Float, Float, Float)] = [
        (0.20, 0.85, 1.00),
        (1.00, 0.85, 0.20),
        (0.40, 0.95, 0.45),
        (1.00, 0.55, 0.20),
        (1.00, 0.45, 0.75),
        (0.70, 0.55, 1.00),
        (1.00, 0.35, 0.35),
        (0.45, 0.65, 1.00)
    ]

    init(components: [AutoComponent],
         spectrogram: CGImage?,
         sampleRate: Double,
         playback: AudioPlayback) {
        self.allComponents = components
        self.spectrogram = spectrogram
        self.sampleRate = sampleRate
        self._playback = ObservedObject(wrappedValue: playback)
        self._items = State(initialValue: components)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                preview

                List {
                    Section(header: Text("Составляющие · \(items.count)")) {
                        ForEach(items) { comp in
                            row(for: comp)
                        }
                        .onDelete(perform: delete)
                    }
                    Section {
                        Text("Кнопка «Играть все» проигрывает все оставшиеся составляющие вместе (то, что вы не удалили). «Найти источник» открывает искатель направления: поворачивайте телефон — стрелка покажет, куда навестись на выбранный звук. Свайп по строке или «Удалить» убирает составляющую.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Составляющие звука")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        togglePlayAll()
                    } label: {
                        Label(playingAll ? "Стоп" : "Играть все",
                              systemImage: playingAll ? "stop.fill" : "play.fill")
                    }
                    .disabled(items.isEmpty)

                    if items.count < allComponents.count {
                        Button("Вернуть") { restore() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { rebuildOverlay() }
        .onChange(of: playingID) { _ in rebuildOverlay() }
        .onChange(of: playingAll) { _ in rebuildOverlay() }
        .onChange(of: items.count) { _ in rebuildOverlay() }
        .onChange(of: playback.isPlaying) { playing in
            if !playing {
                playingAll = false
                playingID = nil
                rebuildOverlay()
            }
        }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        .fullScreenCover(item: $finderComponent) { comp in
            SoundFinderView(component: comp)
        }
    }

    // MARK: - Превью спектра с подсветкой

    private var preview: some View {
        ZStack {
            if let spec = spectrogram {
                Image(decorative: spec, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.5)
            } else {
                Color.black
            }

            if let ov = overlayImage {
                Image(decorative: ov, scale: 1)
                    .resizable()
                    .interpolation(.none)
            }

            GeometryReader { geo in
                if playback.isPlaying {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 1.5)
                        .offset(x: CGFloat(playback.progress) * (geo.size.width - 1.5))
                }
            }
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func row(for comp: AutoComponent) -> some View {
        HStack(spacing: 12) {
            Button {
                toggle(comp)
            } label: {
                Image(systemName: isActive(comp) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)

            Circle()
                .fill(color(for: comp))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(comp.title)
                    .font(.system(size: 15, weight: .medium))
                if !comp.detail.isEmpty {
                    Text(comp.detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()

            Menu {
                Button {
                    finderComponent = comp
                } label: {
                    Label("Найти источник", systemImage: "location.north.line")
                }
                Button {
                    exportURL = comp.url
                    showShare = true
                } label: {
                    Label("Сохранить WAV", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    remove(comp)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
        }
    }

    private func isActive(_ comp: AutoComponent) -> Bool {
        (playingID == comp.id && playback.isPlaying) || playingAll
    }

    private func color(for comp: AutoComponent) -> Color {
        guard let index = items.firstIndex(where: { $0.id == comp.id }) else { return .gray }
        let c = Self.palette[index % Self.palette.count]
        return Color(red: Double(c.0), green: Double(c.1), blue: Double(c.2))
    }

    // MARK: - Действия со списком

    private func toggle(_ comp: AutoComponent) {
        if playingID == comp.id && playback.isPlaying {
            playback.stop()
            playingID = nil
            playingAll = false
        } else {
            playingAll = false
            playback.play(url: comp.url)
            playingID = comp.id
        }
    }

    private func togglePlayAll() {
        if playingAll && playback.isPlaying {
            playback.stop()
            playingAll = false
            playingID = nil
            return
        }
        playAll()
    }

    private func playAll() {
        guard !items.isEmpty else { return }
        var count = Int.max
        for comp in items { count = Swift.min(count, comp.samples.count) }
        guard count > 0, count != Int.max else { return }

        var mix = [Float](repeating: 0, count: count)
        for comp in items {
            let s = comp.samples
            for i in 0..<count { mix[i] += s[i] }
        }
        for i in 0..<count {
            mix[i] = Swift.max(-1, Swift.min(1, mix[i]))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mix-\(UUID().uuidString).wav")
        do {
            try WavWriter.write(samples: mix, sampleRate: sampleRate, to: url)
        } catch {
            playback.errorMessage = "Не удалось подготовить микс: \(error.localizedDescription)"
            return
        }
        playingID = nil
        playingAll = true
        playback.play(url: url)
    }

    private func delete(at offsets: IndexSet) {
        playback.stop()
        playingID = nil
        playingAll = false
        items.remove(atOffsets: offsets)
        rebuildOverlay()
    }

    private func remove(_ comp: AutoComponent) {
        playback.stop()
        playingID = nil
        playingAll = false
        items.removeAll { $0.id == comp.id }
        rebuildOverlay()
    }

    private func restore() {
        playback.stop()
        playingID = nil
        playingAll = false
        items = allComponents
        rebuildOverlay()
    }

    // MARK: - Сборка цветного слоя

    private func rebuildOverlay() {
        overlayImage = makeOverlay()
    }

    private func makeOverlay() -> CGImage? {
        guard let first = items.first else { return nil }
        let cols = first.previewCols
        let rows = first.previewRows
        guard cols > 0, rows > 0 else { return nil }
        let cellCount = cols * rows

        var px = [UInt8](repeating: 0, count: cellCount * 4)
        let anyFocus = playingAll || playingID != nil

        for (index, comp) in items.enumerated() {
            guard comp.preview.count == cellCount else { continue }
            let isFocus = playingAll || (playingID == comp.id)
            let alphaScale: Float = anyFocus ? (isFocus ? 1.0 : 0.18) : 0.75
            let c = Self.palette[index % Self.palette.count]
            let p = comp.preview
            for i in 0..<cellCount {
                let v = p[i]
                if v <= 0.08 { continue }
                let a = Swift.min(1, v) * alphaScale
                if a <= 0 { continue }
                let base = i * 4
                let sr = c.0 * a
                let sg = c.1 * a
                let sb = c.2 * a
                let da = Float(px[base + 3]) / 255
                let inv = 1 - a
                let oa = a + da * inv
                px[base + 0] = UInt8(Swift.min(255, Swift.max(0, (sr + Float(px[base + 0]) / 255 * inv) * 255)))
                px[base + 1] = UInt8(Swift.min(255, Swift.max(0, (sg + Float(px[base + 1]) / 255 * inv) * 255)))
                px[base + 2] = UInt8(Swift.min(255, Swift.max(0, (sb + Float(px[base + 2]) / 255 * inv) * 255)))
                px[base + 3] = UInt8(Swift.min(255, Swift.max(0, oa * 255)))
            }
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: cols,
                       height: rows,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: cols * 4,
                       space: space,
                       bitmapInfo: info,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

// MARK: - Искатель направления

struct SoundFinderView: View {
    let component: AutoComponent
    @StateObject private var finder: SoundFinder
    @Environment(\.dismiss) private var dismiss

    init(component: AutoComponent) {
        self.component = component
        self._finder = StateObject(wrappedValue: SoundFinder(bandLow: component.bandLow,
                                                             bandHigh: component.bandHigh))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text(bandText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                dial

                levelBar

                Text(hint)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Spacer(minLength: 0)

                Button {
                    if finder.isRunning {
                        finder.stop()
                    } else {
                        finder.start()
                    }
                } label: {
                    Label(finder.isRunning ? "Стоп" : "Начать поиск",
                          systemImage: finder.isRunning ? "stop.fill" : "location.north.line.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(finder.isRunning ? .red : .accentColor)
            }
            .padding()
            .navigationTitle(component.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .alert("Ошибка", isPresented: Binding(
            get: { finder.errorMessage != nil },
            set: { if !$0 { finder.errorMessage = nil } }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(finder.errorMessage ?? "")
        }
    }

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 2)

            ForEach(0..<12, id: \.self) { i in
                Rectangle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(width: 1.5, height: 10)
                    .offset(y: -108)
                    .rotationEffect(.degrees(Double(i) * 30))
            }

            Image(systemName: "location.north.fill")
                .font(.system(size: 96))
                .foregroundColor(finder.hasDirection ? .accentColor : Color.gray.opacity(0.5))
                .rotationEffect(.degrees(finder.arrowDegrees))
                .animation(.easeOut(duration: 0.12), value: finder.arrowDegrees)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 240, height: 240)
    }

    private var levelBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Уровень выбранного звука")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f дБ", finder.levelDB))
                    .font(.system(size: 12, design: .monospaced))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * levelFraction)
                }
            }
            .frame(height: 14)
            Text(String(format: "Максимум: %.0f дБ", finder.bestDB))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var levelFraction: CGFloat {
        let lo: Float = -80
        let hi: Float = -10
        let v = (finder.levelDB - lo) / (hi - lo)
        return CGFloat(Swift.max(0, Swift.min(1, v)))
    }

    private var bandText: String {
        if component.bandLow <= 0 {
            return "Широкополосный звук"
        }
        return "Полоса \(frequencyText(component.bandLow))–\(frequencyText(component.bandHigh))"
    }

    private func frequencyText(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1f кГц", hz / 1000)
        }
        return String(format: "%.0f Гц", hz)
    }

    private var hint: String {
        if !finder.motionAvailable {
            return "На этом устройстве недоступен датчик ориентации, искатель направления не работает."
        }
        if !finder.isRunning {
            return "Нажмите «Начать поиск»."
        }
        if !finder.hasDirection {
            return "Медленно поворачивайте телефон, пока не поймаете самый громкий звук выбранной составляющей."
        }
        return "Стрелка показывает, где выбранный звук был громче всего. Поворачивайтесь, пока стрелка не укажет вперёд (вверх). Полоса уровня поможет понять, приближаетесь ли вы к источнику."
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SpectrogramSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Преобразование")) {
                    Picker("Размер БПФ", selection: $settings.fftSize) {
                        ForEach(SpectrogramSettings.fftSizes, id: \.self) { size in
                            Text("\(size)").tag(size)
                        }
                    }
                    Picker("Максимальная частота", selection: $settings.maxFrequency) {
                        ForEach(SpectrogramSettings.maxFrequencies, id: \.self) { f in
                            Text(AxisTicks.formatFrequencyFull(f)).tag(f)
                        }
                    }
                    Toggle("Логарифмическая шкала частот", isOn: $settings.logScale)
                }
                Section(header: Text("Отображение")) {
                    Picker("Динамический диапазон", selection: $settings.dynamicRange) {
                        ForEach(SpectrogramSettings.dynamicRanges, id: \.self) { r in
                            Text("\(Int(r)) дБ").tag(r)
                        }
                    }
                    Picker("Цветовая схема", selection: $settings.colorMap) {
                        ForEach(ColorMap.allCases) { map in
                            Text(map.title).tag(map)
                        }
                    }
                }
                Section(header: Text("Справка")) {
                    Text("Чтобы разделить звук на составляющие: остановите запись и нажмите «Авто» — приложение само найдёт отдельные тона, ударные и шум. Каждую составляющую можно прослушать, увидеть её расположение по частоте и времени, удалить ненужную, проиграть оставшиеся вместе и найти источник звука по направлению. Либо проведите пальцем по спектрограмме (это выделит область «частота × время»), затем «Выдел.» проиграет только её, а «Остал.» — всё, кроме неё.")
                        .font(.system(size: 13))
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
