import AppKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, permissions, model, shortcuts, tryIt
    var id: Int { rawValue }
}

/// First-run flow: welcome → permissions → model → shortcuts → try it.
struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var forward = true

    private var permissions = Permissions.shared
    private var models = ModelManager.shared

    init() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["FLUSSO_DEBUG_STEP"].flatMap(Int.init),
           let debugStep = OnboardingStep(rawValue: raw) {
            _step = State(initialValue: debugStep)
        }
        #endif
    }

    private var recommendedModel: ModelInfo {
        ModelCatalog.models.first(where: \.isRecommended) ?? ModelCatalog.models[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.top, 6)

            GeometryReader { geo in
                ScrollView {
                    page
                        .frame(maxWidth: 540)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            .clipped()

            bottomBar
        }
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                               startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        }
        .background(WindowTitle(title: "Flusso"))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .permissions: PermissionsPage()
        case .model: ModelPage(model: recommendedModel)
        case .shortcuts: ShortcutsPage()
        case .tryIt: TryItPage()
        }
    }

    // MARK: Navigation

    private var canContinue: Bool {
        switch step {
        case .permissions: permissions.allGranted
        case .model: models.isInstalled(recommendedModel)
        default: true
        }
    }

    private var canSkip: Bool {
        (step == .permissions || step == .model) && !canContinue
    }

    private var continueTitle: String {
        switch step {
        case .welcome: "Inizia"
        case .tryIt: "Fine"
        default: "Continua"
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Indietro") { go(-1) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if canSkip {
                Button("Salta") { go(1) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            Button {
                if step == .tryIt {
                    AppSettings.shared.hasCompletedOnboarding = true
                } else {
                    go(1)
                }
            } label: {
                Text(continueTitle).frame(minWidth: 90)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(step == .tryIt ? nil : .defaultAction)
            .disabled(!canContinue)
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }
}

// MARK: - Progress indicator

private struct StepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: step == current ? 28 : 8, height: 8)
            }
        }
        .animation(.smooth, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Passo \(current.rawValue + 1) di \(OnboardingStep.allCases.count)")
    }
}

// MARK: - Shared page chrome

private struct PageHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 56)
            Text(title)
                .font(.system(size: 28, weight: .bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Glass container for onboarding rows.
private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                Text("Benvenuto in Flusso")
                    .font(.system(size: 34, weight: .bold))
                Text("Detta ovunque sul tuo Mac. Gratis, privato, tutto in locale.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(symbol: "mic.fill", color: .orange,
                           title: "Tieni premuto e parla",
                           detail: "Rilascia il tasto e il testo appare nel campo in cui stai scrivendo.")
                FeatureRow(symbol: "lock.fill", color: .blue,
                           title: "Privato per davvero",
                           detail: "La trascrizione avviene sul tuo Mac: nessun audio lascia il computer.")
                FeatureRow(symbol: "globe", color: .green,
                           title: "25 lingue",
                           detail: "Parla in italiano, inglese o cambia lingua quando vuoi.")
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemName: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PermissionsPage: View {
    private var permissions = Permissions.shared
    @State private var askedAccessibility = false

    var body: some View {
        VStack(spacing: 26) {
            PageHeader(systemImage: "hand.raised.fill",
                       title: "Due permessi e ci sei",
                       subtitle: "Flusso ha bisogno di sentire la tua voce e di scrivere al posto tuo.")
            GlassCard {
                PermissionRow(symbol: "mic.fill", color: .orange,
                              title: "Microfono",
                              detail: "Per registrare la tua voce mentre detti.",
                              granted: permissions.microphone == .granted) {
                    if permissions.microphone == .denied {
                        Button("Apri Impostazioni") { permissions.openMicrophoneSettings() }
                    } else {
                        Button("Consenti") {
                            Task { await permissions.requestMicrophone() }
                        }
                    }
                }
                Divider().padding(.leading, 66)
                PermissionRow(symbol: "accessibility", color: .blue,
                              title: "Accessibilità",
                              detail: "Serve per la scorciatoia globale e per incollare il testo nel campo attivo.",
                              granted: permissions.accessibility) {
                    if askedAccessibility {
                        Button("Apri Impostazioni") { permissions.openAccessibilitySettings() }
                    } else {
                        Button("Consenti") {
                            permissions.requestAccessibility()
                            askedAccessibility = true
                        }
                    }
                }
            }
            Text("Se Flusso è già nell'elenco Accessibilità ma risulta non autorizzato, rimuovilo con «–» e aggiungilo di nuovo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow<Action: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 14) {
            IconTile(systemName: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                GrantedLabel().transition(.scale.combined(with: .opacity))
            } else {
                action.buttonStyle(.glass)
            }
        }
        .padding(16)
        .animation(.snappy, value: granted)
    }
}

private struct ModelPage: View {
    let model: ModelInfo

    var body: some View {
        VStack(spacing: 26) {
            PageHeader(systemImage: "arrow.down.circle.fill",
                       title: "Scarica il modello",
                       subtitle: "Il riconoscimento vocale gira sul tuo Mac. Serve un download, una volta sola.")
            GlassCard {
                ModelCard(model: model, compact: true)
            }
            Text("Puoi continuare mentre il download procede: lo trovi anche in Impostazioni › Modelli.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            // Already installed (e.g. onboarding shown again) but not loaded yet.
            if ModelManager.shared.isInstalled(model), AppController.shared.engineStatus == .noModel {
                AppController.shared.selectModel(model)
            }
        }
    }
}

private struct ShortcutsPage: View {
    private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 26) {
            PageHeader(systemImage: "keyboard.fill",
                       title: "Le tue scorciatoie",
                       subtitle: "Due modi per dettare. Fai clic su una scorciatoia per cambiarla.")
            GlassCard {
                ShortcutRow(title: "Detta",
                            detail: "Tieni premuto \(settings.holdShortcut.displayString) per dettare, rilascia per incollare.",
                            kind: .hold)
                Divider().padding(.leading, 18)
                ShortcutRow(title: "Mani libere",
                            detail: "\(settings.lockShortcut.displayString) per la modalità mani libere (premi di nuovo per terminare).",
                            kind: .lock)
            }
            FnKeyTip()
                .padding(16)
                .card()
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let detail: String
    let kind: ShortcutKind

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ShortcutRecorder(kind)
        }
        .padding(16)
    }
}

private struct TryItPage: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    private var settings = AppSettings.shared
    private var controller = AppController.shared
    private var permissions = Permissions.shared

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(systemImage: "waveform",
                       title: "Prova adesso",
                       subtitle: "Fai clic nel riquadro, tieni premuto \(settings.holdShortcut.displayString) e parla. Rilascia per vedere il testo.")

            TextEditor(text: $text)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(12)
                .frame(height: 150)
                .card()
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Prova a dire: «Ciao, sto provando Flusso e funziona benissimo.»")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            statusLine
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            switch (controller.phase, controller.engineStatus) {
            case (.recording, _):
                Image(systemName: "circle.fill").foregroundStyle(.red).symbolEffect(.pulse, options: .repeating)
                Text("In ascolto…")
            case (.transcribing, _):
                ProgressView().controlSize(.small)
                Text("Trascrizione in corso…")
            case (_, .loading):
                ProgressView().controlSize(.small)
                Text("Caricamento del modello…")
            case (_, .noModel):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Il modello non è ancora installato: torna indietro per scaricarlo.")
            case (_, .failed(let message)):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message)
            case (_, .ready):
                if permissions.allGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Pronto. Puoi usare Flusso in qualsiasi app.")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Mancano dei permessi: torna indietro per concederli.")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: controller.phase)
    }
}
