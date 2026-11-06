import AppKit
import SwiftUI

// MARK: - Root

struct OverlayRootView: View {
    let model: OverlayModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear

            if model.state.isPill {
                PillView(state: model.state, reduceMotion: model.reduceMotion)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.pillFrame = $0 }
                    .transition(appearTransition)
            }

            if case .notPasted(let text) = model.state {
                ToastView(text: text, model: model)
                    .id(model.toastID)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { model.toastFrame = $0 }
                    .transition(appearTransition)
            }
        }
        .padding(.bottom, OverlayLayout.shapeBottomInset)
        .frame(width: OverlayLayout.panelSize.width, height: OverlayLayout.panelSize.height)
    }

    private var appearTransition: AnyTransition {
        if model.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.55, anchor: .bottom)
                .combined(with: .offset(y: 10))
                .combined(with: .opacity),
            removal: .scale(scale: 0.7, anchor: .bottom)
                .combined(with: .opacity)
        )
    }
}

// MARK: - Shared chrome

private struct OverlayChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(Color.black)
                    .overlay { shape.strokeBorder(Color(white: 0.24), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
    }
}

// MARK: - Pill

struct PillView: View {
    let state: OverlayState
    let reduceMotion: Bool

    private var isLocked: Bool { state == .recording(.locked) }
    private var isProcessing: Bool { state == .transcribing }

    var body: some View {
        HStack(spacing: 0) {
            if isLocked {
                PillButton(kind: .cancel) { AppController.shared.cancelRecording() }
                    .padding(.trailing, OverlayLayout.buttonGap)
                    .transition(buttonTransition)
            }

            WaveformView(processing: isProcessing)
                .frame(width: OverlayLayout.waveformWidth, height: OverlayLayout.barMaxHeight)

            if isLocked {
                PillButton(kind: .finish) { AppController.shared.finishRecording() }
                    .padding(.leading, OverlayLayout.buttonGap)
                    .transition(buttonTransition)
            }
        }
        .padding(.horizontal, isLocked ? OverlayLayout.buttonInset : OverlayLayout.holdHorizontalPadding)
        .frame(height: OverlayLayout.pillHeight)
        // Buttons are revealed by the widening capsule instead of floating outside it.
        .clipShape(Capsule())
        .modifier(OverlayChrome(shape: Capsule()))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isProcessing ? "Trascrizione in corso" : "Registrazione in corso")
    }

    private var buttonTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity)
    }
}

private struct PillButton: View {
    enum Kind { case cancel, finish }
    let kind: Kind
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(kind == .cancel ? Color(red: 0.30, green: 0.29, blue: 0.26) : .white)
                Image(systemName: kind == .cancel ? "xmark" : "checkmark")
                    .font(.system(size: kind == .cancel ? 8.5 : 9.5, weight: .bold))
                    .foregroundStyle(kind == .cancel ? Color.white : Color.black)
            }
            .frame(width: OverlayLayout.buttonDiameter, height: OverlayLayout.buttonDiameter)
            .brightness(hovered ? (kind == .cancel ? 0.08 : -0.08) : 0)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(kind == .cancel ? "Annulla" : "Fine")
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Waveform

struct WaveformView: View {
    let processing: Bool
    @State private var engine = WaveformEngine()

    var body: some View {
        TimelineView(.animation) { context in
            let bars = engine.step(date: context.date, processing: processing)
            Canvas { gc, size in
                let w = OverlayLayout.barWidth
                let pitch = w + OverlayLayout.barSpacing
                let totalWidth = CGFloat(bars.count) * pitch - OverlayLayout.barSpacing
                var x = (size.width - totalWidth) / 2
                for bar in bars {
                    let h = OverlayLayout.barMinHeight
                        + (OverlayLayout.barMaxHeight - OverlayLayout.barMinHeight) * bar.height
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                    gc.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                            with: .color(.white.opacity(bar.opacity)))
                    x += pitch
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Turns the raw mic levels into smoothed per-bar heights (and drives the
/// processing animation). Reference type so it keeps state across frames.
final class WaveformEngine {
    struct Bar { var height: CGFloat; var opacity: Double }

    private var heights = [CGFloat](repeating: 0, count: OverlayLayout.barCount)
    private var opacities = [Double](repeating: 1, count: OverlayLayout.barCount)
    private var lastDate: Date?
    private var processingStart: Date?

    func step(date: Date, processing: Bool) -> [Bar] {
        let n = OverlayLayout.barCount
        let center = CGFloat(n - 1) / 2
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1)
        lastDate = date
        let t = date.timeIntervalSinceReferenceDate

        var targetH = [CGFloat](repeating: 0, count: n)
        var targetO = [Double](repeating: 1, count: n)

        if processing {
            if processingStart == nil { processingStart = date }
            let elapsed = date.timeIntervalSince(processingStart!)
            // A soft bump travelling back and forth across the bars.
            let pos = center + (center + 1.5) * CGFloat(sin(elapsed * 2.6 - .pi / 2))
            for i in 0..<n {
                let d = CGFloat(i) - pos
                let bump = exp(-(d * d) / 3.0)
                targetH[i] = 0.06 + 0.30 * bump
                targetO[i] = 0.35 + 0.65 * Double(bump)
            }
        } else {
            processingStart = nil
            let history = AppController.shared.levels.snapshot(count: 32)
            let newest = history.count - 1
            for i in 0..<n {
                let d = abs(CGFloat(i) - center)
                // Center bar shows the newest level; outer bars slightly older
                // ones, so loudness ripples outward symmetrically.
                let idx = max(0, newest - Int(d))
                let level = CGFloat(max(history[idx], history[max(0, idx - 1)], history[max(0, idx - 2)]))
                let shaped = pow(level, 0.8)
                let envelope = 0.28 + 0.72 * exp(-pow(d / 2.9, 2))
                let wobble = 0.85 + 0.15 * CGFloat(sin(t * (6.5 + Double(i) * 0.9) + Double(i) * 1.7))
                targetH[i] = min(1, shaped * envelope * wobble * 1.15)
                targetO[i] = 1
            }
        }

        for i in 0..<n {
            let rising = targetH[i] > heights[i]
            let rate: Double = processing ? 9 : (rising ? 28 : 10)
            let k = CGFloat(1 - exp(-rate * dt))
            heights[i] += (targetH[i] - heights[i]) * k
            opacities[i] += (targetO[i] - opacities[i]) * Double(k)
        }
        return (0..<n).map { Bar(height: heights[$0], opacity: opacities[$0]) }
    }
}

// MARK: - Not-pasted toast

struct ToastView: View {
    let text: String
    let model: OverlayModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nessun campo di testo attivo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CopyButton(copied: model.toastCopied, progress: model.toastProgress) {
                OverlayController.shared.copyToastText()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .frame(width: OverlayLayout.toastWidth)
        .overlay(alignment: .topTrailing) {
            CloseButton { OverlayController.shared.dismissToast() }
                .offset(x: 6, y: -6)
                .opacity(model.toastHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: model.toastHovered)
        }
        .modifier(OverlayChrome(shape: RoundedRectangle(cornerRadius: OverlayLayout.toastCornerRadius,
                                                       style: .continuous)))
    }
}

private struct CopyButton: View {
    let copied: Bool
    let progress: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        CountdownRing(progress: progress)
                            .transition(.opacity)
                    }
                }
                .frame(width: 12, height: 12)

                Text(copied ? "Copiato" : "Copia")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(.black)
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .frame(height: 26)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: copied)
        .accessibilityLabel(copied ? "Copiato" : "Copia")
    }
}

private struct CountdownRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(white: 0.22)))
                .overlay(Circle().strokeBorder(Color(white: 0.36), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Chiudi")
    }
}
