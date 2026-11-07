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
    case home, history, dictionary, snippets, formatting, shortcuts, microphone, languages, models, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .formatting: "Formatting"
        case .shortcuts: "Shortcuts"
        case .microphone: "Microphone"
        case .languages: "Languages"
        case .models: "Models"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .history: "clock.fill"
        case .dictionary: "character.book.closed.fill"
        case .snippets: "text.bubble.fill"
        case .formatting: "wand.and.stars"
        case .shortcuts: "keyboard.fill"
        case .microphone: "mic.fill"
        case .languages: "globe"
        case .models: "cpu.fill"
        case .general: "gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .home: .blue
        case .history: .orange
        case .dictionary: .purple
        case .snippets: .green
        case .formatting: .purple
        case .shortcuts: .gray
        case .microphone: .pink
        case .languages: .teal
        case .models: .indigo
        case .general: .gray
        }
    }

    static let main: [SidebarPage] = [.home, .history, .dictionary, .snippets]
    static let settings: [SidebarPage] = [.formatting, .shortcuts, .microphone, .languages, .models, .general]
}

struct MainSplitView: View {
    @State private var selection: SidebarPage? = .home
    /// Back/forward navigation between pages, like System Settings.
    @State private var backStack: [SidebarPage] = []
    @State private var forwardStack: [SidebarPage] = []
    @State private var navigatingHistory = false
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
                        SidebarRow(page: page).tag(page)
                    }
                }
                Section("Settings") {
                    ForEach(SidebarPage.settings) { page in
                        SidebarRow(page: page).tag(page)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarStatus()
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(for: selection ?? .home)
                .id(selection)
                .transition(.opacity)
                // Every page has the same toolbar (back/forward + title, plus
                // the page's own items). A page without any toolbar item would
                // make SwiftUI drop its toolbar and shift the window chrome.
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left", action: goBack)
                            .help("Back")
                            .keyboardShortcut("[", modifiers: .command)
                            .disabled(backStack.isEmpty)
                        Button("Forward", systemImage: "chevron.right", action: goForward)
                            .help("Forward")
                            .keyboardShortcut("]", modifiers: .command)
                            .disabled(forwardStack.isEmpty)
                    }
                }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
        .onChange(of: selection) { old, _ in
            if navigatingHistory {
                navigatingHistory = false
            } else if let old {
                backStack.append(old)
                forwardStack.removeAll()
            }
        }
        .background(WindowTitle(title: (selection ?? .home).title))
        #if DEBUG
        .task { await DebugUI.cycle($selection) }
        #endif
    }

    private func goBack() {
        guard let page = backStack.popLast() else { return }
        if let selection { forwardStack.append(selection) }
        navigatingHistory = true
        selection = page
    }

    private func goForward() {
        guard let page = forwardStack.popLast() else { return }
        if let selection { backStack.append(selection) }
        navigatingHistory = true
        selection = page
    }

    @ViewBuilder
    private func detail(for page: SidebarPage) -> some View {
        switch page {
        case .home: HomeView(selection: $selection)
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .formatting: FormattingSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .microphone: MicrophoneSettingsView()
        case .languages: LanguagesSettingsView()
        case .models: ModelsSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

private struct SidebarRow: View {
    let page: SidebarPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            IconTile(systemName: page.symbol, color: page.color, size: 22)
        }
    }
}

/// Live status at the bottom of the sidebar.
private struct SidebarStatus: View {
    var body: some View {
        let status = FlussoStatus.current
        HStack(spacing: 8) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 0) {
                Text(status.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .animation(.snappy, value: status.title)
    }
}

#if DEBUG
/// Debug-only hooks to open a given screen directly (for screenshots):
/// `FLUSSO_DEBUG_PAGE=models` or `FLUSSO_DEBUG_STEP=2`.
enum DebugUI {
    static var page: SidebarPage? {
        ProcessInfo.processInfo.environment["FLUSSO_DEBUG_PAGE"].flatMap(SidebarPage.init(rawValue:))
    }

    /// `FLUSSO_DEBUG_CYCLE=<seconds>`: walks through every page (to check
    /// that the window chrome doesn't move while navigating).
    static func cycle(_ selection: Binding<SidebarPage?>) async {
        guard let interval = ProcessInfo.processInfo.environment["FLUSSO_DEBUG_CYCLE"].flatMap(Double.init) else { return }
        while !Task.isCancelled {
            for page in SidebarPage.allCases {
                try? await Task.sleep(for: .seconds(interval))
                selection.wrappedValue = page
            }
        }
    }
}
#endif
