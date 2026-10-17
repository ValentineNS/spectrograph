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

struct SpectrographScreen: View {
    @ObservedObject var settings: SpectrogramSettings
    @ObservedObject var analyzer: AudioAnalyzer

    @State private var showSettings = false
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var pixelWidth: Double = 0

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
                                onPixelWidth: { pixelWidth = $0 })
                    .background(Color.black)
                    .overlay(Rectangle().stroke(Color.gray.opacity(0.35), lineWidth: 1))
                    .clipped()
            }

            TimeAxisView(historySeconds: historySeconds)
                .frame(height: 16)
                .padding(.leading, 46)

            controls
        }
        .padding(8)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .sheet(isPresented: $showShare) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { analyzer.errorMessage != nil },
            set: { present in if !present { analyzer.errorMessage = nil } }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(analyzer.errorMessage ?? "")
        }
    }

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

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                if analyzer.isRunning {
                    analyzer.stop()
                } else {
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
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 32)
            }
            .buttonStyle(.bordered)

            Button {
                exportPNG()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 32)
            }
            .buttonStyle(.bordered)
        }
    }

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
            exportURL = url
            showShare = true
        } catch {
            analyzer.errorMessage = "Не удалось сохранить PNG: \(error.localizedDescription)"
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
