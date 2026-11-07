import AppKit
import SwiftUI

/// How dictated text is formatted before it's inserted.
struct FormattingSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var availability = SmartFormatter.availability
    @State private var sample = ""
    @State private var result: String?
    @State private var formatting = false

    var body: some View {
        PageScroll {
            PageHero(symbol: "wand.and.stars", color: .purple,
                     title: "Formatting",
                     description: "Flusso tidies up what you say before inserting it — on your Mac, without sending anything anywhere.")

            styles

            smartFormatting
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            availability = SmartFormatter.availability
        }
    }

    // MARK: Styles

    private var styles: some View {
        SectionCard(title: "Style by App",
                    footer: "Styles only change capitals and punctuation, never your words. Flusso uses the style of the app you’re dictating into.") {
            ForEach(DictationStyle.allCases) { style in
                StyleExampleRow(style: style)
                RowDivider(inset: DS.rowHPadding)
            }
            SettingRow(symbol: "square.grid.2x2.fill", color: .gray,
                       title: "All other apps") {
                StylePicker(selection: $settings.defaultStyle)
            }
            ForEach($settings.appStyles) { $entry in
                RowDivider()
                AppStyleRow(entry: $entry) {
                    withAnimation(.snappy) { settings.appStyles.removeAll { $0.bundleID == entry.bundleID } }
                }
            }
        } accessory: {
            AddAppMenu(excluded: Set(settings.appStyles.map(\.bundleID))) { bundleID, name in
                withAnimation(.snappy) {
                    settings.appStyles.append(AppStyle(bundleID: bundleID, name: name, style: .casual))
                }
            }
        }
        .animation(.snappy, value: settings.appStyles)
    }

    // MARK: Smart formatting

    private var formatter = LocalFormatter.shared
    private var models = ModelManager.shared

    private var usesLocal: Bool { LocalFormatter.isSupported && settings.formattingEngine == .local }

    /// The selected model can format right now.
    private var isReady: Bool {
        usesLocal ? formatter.status == .ready : availability == .available
    }

    @ViewBuilder
    private var smartFormatting: some View {
        SectionCard(title: "Smart Formatting",
                    footer: "Runs on this Mac, nothing is sent anywhere. If an edit changes your words, Flusso keeps the original.") {
            ToggleRow(symbol: "arrow.uturn.backward", color: .purple,
                      title: "Fix self-corrections and lists",
                      subtitle: "“At 5, no wait, at 6” becomes “At 6”, and the tasks or items you list become a bulleted or numbered list.",
                      isOn: $settings.smartFormatting)
                .disabled(!usesLocal && availability != .available)
            if LocalFormatter.isSupported {
                RowDivider()
                SettingRow(symbol: "cpu", color: .indigo, title: "Model",
                           subtitle: usesLocal ? localSummary : appleSummary) {
                    Picker("Model", selection: $settings.formattingEngine) {
                        Text("Apple Intelligence").tag(FormattingEngine.apple)
                        Text("Gemma 4 (local)").tag(FormattingEngine.local)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if usesLocal {
                    RowDivider()
                    localModel
                }
            }
            if settings.smartFormatting && isReady {
                RowDivider()
                tester
            }
        }
        .animation(.snappy, value: settings.formattingEngine)

        if !usesLocal, let message = unavailableMessage {
            NoticeCard(symbol: "exclamationmark.triangle.fill", color: .orange,
                       title: "Apple Intelligence not available",
                       message: message + (LocalFormatter.isSupported ? " Or choose Gemma 4, which runs on any Mac with Apple silicon." : "")) {
                if availability == .appleIntelligenceOff {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .glassButtonStyle()
                }
            }
        }
    }

    private var appleSummary: String {
        "Built into macOS 26 and later. Runs only when you correct yourself or number a list aloud (“first… second…”), so most dictations aren’t slowed down."
    }

    private var localSummary: String {
        "More accurate: also spots lists you don’t number, in any language. Reads every dictation (about 0.1 s for a sentence, 1 s for a long list)."
    }

    /// Gemma's download state, size and memory use.
    private var localModel: some View {
        let model = ModelCatalog.formattingModel
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(model.name).fontWeight(.medium)
                Label(model.sizeDescription, systemImage: "internaldrive")
                Label("About 6 GB of memory while in use", systemImage: "memorychip")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ModelActions(model: model)
            if !models.isInstalled(model), availability == .available {
                Text("Until it’s downloaded, Apple Intelligence formats your dictations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
    }

    private var unavailableMessage: String? {
        switch availability {
        case .available: nil
        case .unsupportedOS: "Smart formatting needs macOS 26 or later."
        case .deviceNotEligible: "This Mac doesn’t support Apple Intelligence."
        case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings to use smart formatting."
        case .modelNotReady: "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable: "Apple Intelligence isn’t available right now."
        }
    }

    private var tester: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Try it", text: $sample,
                          prompt: Text(usesLocal ? "Try it: Here’s the plan, book the flights, and then call the hotel."
                                                 : "Try it: Call me at 5, no wait, at 6."))
                    .textFieldStyle(.plain)
                    .onSubmit(run)
                    .disabled(formatting)
                    .onChange(of: sample) { result = nil }
                Button("Format", action: run)
                    .glassButtonStyle()
                    .disabled(sample.trimmingCharacters(in: .whitespaces).isEmpty || formatting)
            }
            if formatting {
                ProgressView().controlSize(.small).padding(.leading, 28)
            } else if let result {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: result == sample ? "equal.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(result == sample ? Color.secondary : Color.green)
                        .frame(width: 18)
                    Text(result == sample ? "No changes needed." : result)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
        .animation(.snappy, value: result)
    }

    private func run() {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !formatting else { return }
        formatting = true
        let input = sample
        Task {
            let output = await SmartFormatter.format(text)
            formatting = false
            guard sample == input else { return }
            result = output == text ? input : output
        }
    }
}

// MARK: - Style rows

private struct StylePicker: View {
    @Binding var selection: DictationStyle

    var body: some View {
        Picker("Style", selection: $selection) {
            ForEach(DictationStyle.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// What each style does to the same sentence.
private struct StyleExampleRow: View {
    let style: DictationStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(style.title)
                .font(.callout.weight(.medium))
                .frame(width: 90, alignment: .leading)
            Text(style.apply(DictationStyle.example))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 8)
    }
}

private struct AppStyleRow: View {
    @Binding var entry: AppStyle
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(bundleID: entry.bundleID)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 12)
            StylePicker(selection: $entry.style)
            HoverIconButton(symbol: "minus.circle", help: "Remove", role: .destructive, action: onRemove)
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, DS.rowVPadding)
        .frame(minHeight: 46)
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!)
            .resizable()
            .interpolation(.high)
            .frame(width: DS.rowIcon, height: DS.rowIcon)
    }
}

/// Running apps first, or any app from the Applications folder.
private struct AddAppMenu: View {
    let excluded: Set<String>
    let add: (_ bundleID: String, _ name: String) -> Void

    private var runningApps: [(id: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (id: String, name: String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      !excluded.contains(id), seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu("Add App") {
            let apps = runningApps
            if !apps.isEmpty {
                Section("Open Apps") {
                    ForEach(apps, id: \.id) { app in
                        Button(app.name) { add(app.id, app.name) }
                    }
                }
            }
            Button("Choose…", action: choose)
        }
        .menuStyle(.button)
        .buttonStyle(.link)
        .font(.callout)
        .fixedSize()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        guard !excluded.contains(id) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(id, name)
    }
}
