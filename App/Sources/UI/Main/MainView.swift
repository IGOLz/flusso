import SwiftUI

/// Root of the main window: onboarding on first run, then the sidebar app.
struct MainView: View {
    private var settings = AppSettings.shared

    private var showOnboarding: Bool {
        #if DEBUG
        if DebugUI.page != nil { return false }
        #endif
        return !settings.hasCompletedOnboarding
    }

    var body: some View {
        ZStack {
            if showOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else {
                MainSplitView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: showOnboarding)
        .frame(minWidth: 720, minHeight: 500)
    }
}

enum SidebarPage: String, Hashable, CaseIterable, Identifiable {
    case home, history, dictionary, shortcuts, microphone, languages, models, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "Cronologia"
        case .dictionary: "Dizionario"
        case .shortcuts: "Scorciatoie"
        case .microphone: "Microfono"
        case .languages: "Lingue"
        case .models: "Modelli"
        case .general: "Generali"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .shortcuts: "keyboard"
        case .microphone: "mic"
        case .languages: "globe"
        case .models: "cpu"
        case .general: "gearshape"
        }
    }

    static let main: [SidebarPage] = [.home, .history, .dictionary]
    static let settings: [SidebarPage] = [.shortcuts, .microphone, .languages, .models, .general]
}

struct MainSplitView: View {
    @State private var selection: SidebarPage? = .home

    init() {
        #if DEBUG
        if let page = DebugUI.page { _selection = State(initialValue: page) }
        #endif
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarPage.main) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
                Section("Impostazioni") {
                    ForEach(SidebarPage.settings) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail(for: selection ?? .home)
                .id(selection)
        }
        .background(WindowTitle(title: (selection ?? .home).title, subtitle: subtitle))
    }

    private var subtitle: String {
        guard selection == .history else { return "" }
        let count = HistoryStore.shared.items.count
        return count == 0 ? "" : count == 1 ? "1 trascrizione" : "\(count) trascrizioni"
    }

    @ViewBuilder
    private func detail(for page: SidebarPage) -> some View {
        switch page {
        case .home: HomeView(selection: $selection)
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .shortcuts: ShortcutsSettingsView()
        case .microphone: MicrophoneSettingsView()
        case .languages: LanguagesSettingsView()
        case .models: ModelsSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

#if DEBUG
/// Debug-only hooks to open a given screen directly (for screenshots):
/// `FLUSSO_DEBUG_PAGE=models` or `FLUSSO_DEBUG_STEP=2`.
enum DebugUI {
    static var page: SidebarPage? {
        ProcessInfo.processInfo.environment["FLUSSO_DEBUG_PAGE"].flatMap(SidebarPage.init(rawValue:))
    }
}
#endif
