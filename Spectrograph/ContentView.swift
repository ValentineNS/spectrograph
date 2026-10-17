import SwiftUI

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
                AutoDecomposeView(components: autoComponents, playback: playback)
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
    let components: [AutoComponent]
    @ObservedObject var playback: AudioPlayback

    @Environment(\.dismiss) private var dismiss
    @State private var playingID: UUID?
    @State private var exportURL: URL?
    @State private var showShare = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Составляющие · \(components.count)")) {
                    ForEach(components) { comp in
                        HStack(spacing: 12) {
                            Button {
                                if playingID == comp.id && playback.isPlaying {
                                    playback.stop()
                                    playingID = nil
                                } else {
                                    playback.play(url: comp.url)
                                    playingID = comp.id
                                }
                            } label: {
                                Image(systemName: (playingID == comp.id && playback.isPlaying)
                                      ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 27))
                            }
                            .buttonStyle(.plain)

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
                            Button {
                                exportURL = comp.url
                                showShare = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Text("Приложение разделило запись на устойчивые тона (по их гармоникам), ударные (стук, щелчки) и шум/остаток. Каждую составляющую можно прослушать и сохранить как WAV. Звуки, совпадающие по частоте и времени, разделить нельзя.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Составляющие звука")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
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
                    Text("Чтобы разделить звук на составляющие: остановите запись и нажмите «Авто» — приложение само найдёт отдельные тона, ударные и шум. Либо проведите пальцем по спектрограмме (это выделит область «частота × время»), затем «Выдел.» проиграет только её, а «Остал.» — всё, кроме неё.")
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
