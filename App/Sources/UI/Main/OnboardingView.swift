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
            GeometryReader { geo in
                if step == .shortcuts {
                    // Fixed layout: this page doesn't scroll. Only if the
                    // window is shrunk below what it needs, fall back to
                    // scrolling rather than clipping.
                    ViewThatFits(in: .vertical) {
                        page
                            .frame(maxWidth: 540)
                            .padding(.horizontal, 32)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            page
                                .frame(maxWidth: 540)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    ScrollView {
                        page
                            .frame(maxWidth: 540)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
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
        // The progress lives in the toolbar: the window keeps the same
        // toolbar height (and traffic-light position) as the main pages.
        .toolbar {
            ToolbarItem(placement: .principal) {
                StepIndicator(current: step)
            }
        }
        .hiddenWindowToolbar()
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
        case .welcome: "Get Started"
        case .tryIt: "Done"
        default: "Continue"
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { go(-1) }
                    .glassButtonStyle()
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if canSkip {
                Button("Skip") { go(1) }
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
            .glassProminentButtonStyle()
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
        .padding(.horizontal, 8)
        .animation(.smooth, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

// MARK: - Shared page chrome

private struct PageHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 36 : 44, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(height: compact ? 44 : 56)
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
            .adaptiveGlass(cornerRadius: 20)
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
                Text("Welcome to Flusso")
                    .font(.system(size: 34, weight: .bold))
                Text("Dictate anywhere on your Mac. Free, private, and fully local.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(symbol: "mic.fill", color: .orange,
                           title: "Hold and speak",
                           detail: "Release the key and your text appears in the field you’re typing in.")
                FeatureRow(symbol: "lock.fill", color: .blue,
                           title: "Truly private",
                           detail: "Transcription happens on your Mac — no audio ever leaves your computer.")
                FeatureRow(symbol: "globe", color: .green,
                           title: "25 languages",
                           detail: "Speak English, Italian, and more — switch languages whenever you like.")
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
                       title: "Two Permissions and You’re Set",
                       subtitle: "Flusso needs to hear your voice and type for you.")
            GlassCard {
                PermissionRow(symbol: "mic.fill", color: .orange,
                              title: "Microphone",
                              detail: "To record your voice while you dictate.",
                              granted: permissions.microphone == .granted) {
                    if permissions.microphone == .denied {
                        Button("Open Settings") { permissions.openMicrophoneSettings() }
                    } else {
                        Button("Allow") {
                            Task { await permissions.requestMicrophone() }
                        }
                    }
                }
                Divider().padding(.leading, 66)
                PermissionRow(symbol: "accessibility", color: .blue,
                              title: "Accessibility",
                              detail: "Required for the global shortcut and to paste text into the active field.",
                              granted: permissions.accessibility) {
                    if askedAccessibility {
                        Button("Open Settings") { permissions.openAccessibilitySettings() }
                    } else {
                        Button("Allow") {
                            permissions.requestAccessibility()
                            askedAccessibility = true
                        }
                    }
                }
            }
            Text("If Flusso is already in the Accessibility list but isn’t allowed, remove it with “–” and add it again.")
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
                action.glassButtonStyle()
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
                       title: "Download the Model",
                       subtitle: "Speech recognition runs on your Mac. It just needs a one-time download.")
            ModelStoragePicker()
            GlassCard {
                ModelCard(model: model, compact: true)
            }
            Text("You can continue while it downloads. You’ll also find it in Settings › Models.")
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
        VStack(spacing: 18) {
            PageHeader(systemImage: "keyboard.fill",
                       title: "Your Shortcuts",
                       subtitle: "Try pressing them — the keys light up. Click a shortcut to change it.",
                       compact: true)
            GlassCard {
                ShortcutRow(title: "Dictate",
                            detail: "Hold \(settings.holdShortcut.displayString) to dictate, release to paste.",
                            kind: .hold)
                Divider().padding(.leading, 18)
                ShortcutRow(title: "Hands-free",
                            detail: "Press \(settings.lockShortcut.displayString) to start hands-free dictation, and again to stop.",
                            kind: .lock)
            }
            if usesFn {
                FnKeyTip()
                    .padding(14)
                    .card()
            }
        }
        // Here the shortcuts only light up; they don't start a dictation.
        .onAppear { AppController.shared.shortcutPreview = true }
        .onDisappear { AppController.shared.shortcutPreview = false }
        // The window is retained when closed: re-arm when it comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            AppController.shared.shortcutPreview = true
        }
    }

    private var usesFn: Bool { settings.dictationUsesFn }
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
            ShortcutList(kind)
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
                       title: "Try It Now",
                       subtitle: "Click in the box, hold \(settings.holdShortcut.displayString), and speak. Release to see the text.")

            TextEditor(text: $text)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(12)
                .frame(height: 150)
                .card()
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Try saying: “Hi, I’m trying out Flusso and it works great.”")
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
                Text("Listening…")
            case (.transcribing, _):
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            case (_, .loading):
                ProgressView().controlSize(.small)
                Text("Loading model…")
            case (_, .noModel):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("The model isn’t installed yet — go back to download it.")
            case (_, .failed(let message)):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message)
            case (_, .ready):
                if permissions.allGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Ready. You can use Flusso in any app.")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Some permissions are missing — go back to grant them.")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .animation(.snappy, value: controller.phase)
    }
}
