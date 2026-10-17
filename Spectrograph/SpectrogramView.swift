import SwiftUI
import UIKit

/// Мост между SwiftUI и слоем «водопада».
struct SpectrogramView: UIViewRepresentable {
    let buffer: WaterfallBuffer
    let fftSize: Int
    let sampleRate: Double
    let maxFrequency: Double
    let logScale: Bool
    let minDB: Float
    let maxDB: Float
    let colorMap: ColorMap
    let onPixelWidth: (Double) -> Void

    func makeUIView(context: Context) -> WaterfallView {
        WaterfallView(buffer: buffer)
    }

    func updateUIView(_ uiView: WaterfallView, context: Context) {
        uiView.configProvider = { w, h in
            buffer.configure(width: w,
                             height: h,
                             fftSize: fftSize,
                             sampleRate: sampleRate,
                             maxFrequency: maxFrequency,
                             logScale: logScale,
                             minDB: minDB,
                             maxDB: maxDB,
                             colorMap: colorMap)
        }
        uiView.onPixelWidth = { pw in
            DispatchQueue.main.async { onPixelWidth(pw) }
        }
        uiView.requestConfigure()
    }
}

/// Ось частот слева от спектрограммы.
struct FrequencyAxisView: View {
    let maxFrequency: Double
    let logScale: Bool

    var body: some View {
        Canvas { ctx, size in
            let ticks = AxisTicks.frequency(maxFrequency: maxFrequency, logScale: logScale)
            for tick in ticks {
                let raw = size.height * (1 - CGFloat(tick.fraction))
                let y = min(max(raw, 6), size.height - 2)
                var path = Path()
                path.move(to: CGPoint(x: size.width - 5, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(Color.gray.opacity(0.6)), lineWidth: 1)
                ctx.draw(Text(tick.label)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary),
                         at: CGPoint(x: size.width - 8, y: y),
                         anchor: .trailing)
            }
        }
    }
}

/// Ось времени под спектрограммой.
struct TimeAxisView: View {
    let historySeconds: Double

    var body: some View {
        Canvas { ctx, size in
            guard historySeconds > 0 else {
                ctx.draw(Text("время, с")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary),
                         at: CGPoint(x: 2, y: size.height),
                         anchor: .bottomLeading)
                return
            }
            for tick in AxisTicks.time(history: historySeconds) {
                let raw = size.width * CGFloat(tick.fraction)
                let x = min(max(raw, 8), size.width - 8)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: 4))
                ctx.stroke(path, with: .color(Color.gray.opacity(0.6)), lineWidth: 1)
                ctx.draw(Text(tick.label)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary),
                         at: CGPoint(x: x, y: 4),
                         anchor: .top)
            }
        }
    }
}

/// Сборка PNG-файла: спектрограмма + подписи осей.
enum SpectrogramExporter {
    static func render(spectrogram: CGImage,
                       maxFrequency: Double,
                       logScale: Bool,
                       historySeconds: Double,
                       caption: String) -> UIImage {
        let leftAxis: CGFloat = 60
        let rightPad: CGFloat = 10
        let topPad: CGFloat = 22
        let bottomAxis: CGFloat = 26

        let specW = max(1, CGFloat(spectrogram.width))
        let specH = max(1, CGFloat(spectrogram.height))
        let totalW = leftAxis + specW + rightPad
        let totalH = topPad + specH + bottomAxis
        let specRect = CGRect(x: leftAxis, y: topPad, width: specW, height: specH)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalW, height: totalH), format: format)

        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor(white: 0.85, alpha: 1)
        ]
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor.white
        ]

        return renderer.image { context in
            let cg = context.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

            UIImage(cgImage: spectrogram).draw(in: specRect)

            cg.setStrokeColor(UIColor(white: 0.6, alpha: 0.9).cgColor)
            cg.setLineWidth(1)
            cg.stroke(specRect)

            // Частотная ось.
            for tick in AxisTicks.frequency(maxFrequency: maxFrequency, logScale: logScale) {
                let raw = specRect.maxY - CGFloat(tick.fraction) * specH
                let y = min(max(raw, specRect.minY + 5), specRect.maxY - 5)
                cg.setStrokeColor(UIColor(white: 0.6, alpha: 0.7).cgColor)
                cg.move(to: CGPoint(x: specRect.minX - 5, y: y))
                cg.addLine(to: CGPoint(x: specRect.minX, y: y))
                cg.strokePath()
                let s = tick.label as NSString
                let sz = s.size(withAttributes: tickAttrs)
                s.draw(at: CGPoint(x: specRect.minX - 8 - sz.width, y: y - sz.height / 2),
                       withAttributes: tickAttrs)
            }

            // Временная ось.
            if historySeconds > 0 {
                for tick in AxisTicks.time(history: historySeconds) {
                    let raw = specRect.minX + CGFloat(tick.fraction) * specW
                    let x = min(max(raw, specRect.minX + 8), specRect.maxX - 8)
                    cg.setStrokeColor(UIColor(white: 0.6, alpha: 0.7).cgColor)
                    cg.move(to: CGPoint(x: x, y: specRect.maxY))
                    cg.addLine(to: CGPoint(x: x, y: specRect.maxY + 4))
                    cg.strokePath()
                    let s = tick.label as NSString
                    let sz = s.size(withAttributes: tickAttrs)
                    s.draw(at: CGPoint(x: x - sz.width / 2, y: specRect.maxY + 6),
                           withAttributes: tickAttrs)
                }
            }

            (caption as NSString).draw(at: CGPoint(x: specRect.minX, y: 5),
                                       withAttributes: captionAttrs)
        }
    }
}
