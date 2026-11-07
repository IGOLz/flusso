import AppKit
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    private var usesFn: Bool {
        settings.holdShortcut.modifiers.contains(.function) || settings.lockShortcut.modifiers.contains(.function)
    }

    private var isDefault: Bool {
        settings.holdShortcut == .holdDefault && settings.lockShortcut == .lockDefault
            && settings.pasteLastShortcut == .pasteLastDefault
    }

    var body: some View {
        PageScroll {
            PageHero(symbol: "keyboard.fill", color: .gray,
                     title: "Shortcuts",
                     description: "Press a shortcut to try it — its keys light up. Click a shortcut to record a new one.")

            SectionCard(title: "Dictation",
                        footer: "You can also use a single modifier, like fn or right ⌥. Press Esc to cancel recording.") {
                SettingRow(symbol: "mic.fill", color: .orange,
                           title: "Hold to dictate",
                           subtitle: "Hold, speak, and release to paste the text.") {
                    ShortcutRecorder(.hold, reservesClearSpace: true)
                }
                RowDivider()
                SettingRow(symbol: "lock.fill", color: .blue,
                           title: "Hands-free mode",
                           subtitle: "Press once to start dictating, again to stop.") {
                    ShortcutRecorder(.lock, reservesClearSpace: true)
                }
                RowDivider()
                SettingRow(symbol: "arrow.uturn.backward.circle.fill", color: .purple,
                           title: "Paste last transcription",
                           subtitle: "Pastes your latest dictation again, e.g. if it went into the wrong field.") {
                    ShortcutRecorder(.pasteLast)
                }
            } accessory: {
                Button("Restore Defaults") {
                    withAnimation(.snappy) {
                        settings.holdShortcut = .holdDefault
                        settings.lockShortcut = .lockDefault
                        settings.pasteLastShortcut = .pasteLastDefault
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(isDefault)
            }

            if usesFn {
                FnKeyTip()
                    .padding(16)
                    .cardSurface()
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: usesFn)
    }
}

// MARK: - Microphone

struct MicrophoneSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private var permissions = Permissions.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDeviceName: String?

    var body: some View {
        PageScroll {
            PageHero(symbol: "mic.fill", color: .pink,
                     title: "Microphone",
                     description: "Choose which device Flusso records your voice from and how it behaves while recording.")

            if permissions.microphone != .granted {
                NoticeCard(symbol: "mic.slash.fill",
                           title: "Microphone access needed",
                           message: "Allow Flusso to use the microphone so you can dictate.") {
                    Button(permissions.microphone == .denied ? "Open Settings" : "Allow") {
                        if permissions.microphone == .denied {
                            permissions.openMicrophoneSettings()
                        } else {
                            Task { await permissions.requestMicrophone() }
                        }
                    }
                    .glassButtonStyle()
                }
            }

            SectionCard(title: "Input Device") {
                DeviceRow(symbol: "gearshape.fill", color: .gray,
                          title: "System default",
                          subtitle: defaultDeviceName ?? "Follows System Settings",
                          isSelected: settings.microphoneUID == nil) {
                    settings.microphoneUID = nil
                }
                ForEach(devices) { device in
                    RowDivider()
                    DeviceRow(symbol: Self.symbol(for: device.name), color: .pink,
                              title: device.name, subtitle: nil,
                              isSelected: settings.microphoneUID == device.uid) {
                        settings.microphoneUID = device.uid
                    }
                }
                if let uid = settings.microphoneUID, !devices.contains(where: { $0.uid == uid }) {
                    RowDivider()
                    DeviceRow(symbol: "mic.slash.fill", color: .orange,
                              title: "Device not connected",
                              subtitle: "Reconnect it or choose another one.",
                              isSelected: true) {}
                }
            }

            SectionCard(title: "Recording") {
                ToggleRow(symbol: "bolt.fill", color: .orange,
                          title: "Instant start",
                          subtitle: "Keeps the microphone ready, so recording starts in 0 ms and even catches the moment before you press the key. While it’s on, macOS shows the orange microphone indicator.",
                          isOn: $settings.instantStart)
                RowDivider()
                ToggleRow(symbol: "speaker.wave.2.fill", color: .blue,
                          title: "Sounds",
                          subtitle: "Play a sound when recording starts and stops.",
                          isOn: $settings.playSounds)
            }
        }
        .task { reloadDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadDevices()
        }
    }

    private static func symbol(for name: String) -> String {
        // Device names are localized by macOS, so match Italian names too.
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("iphone") { return "iphone" }
        if lower.contains("macbook") || lower.contains("built-in") || lower.contains("integrato") { return "laptopcomputer" }
        if lower.contains("headset") || lower.contains("cuffie") || lower.contains("headphone") { return "headphones" }
        return "mic.fill"
    }

    private func reloadDevices() {
        let list = AudioDevices.inputDevices()
        devices = list
        let defaultID = AudioDevices.defaultInputDeviceID()
        defaultDeviceName = list.first { $0.id == defaultID }?.name
    }
}

/// A selectable row with a radio-style checkmark.
private struct DeviceRow: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SettingRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .background(hovering ? Color.rowHover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Languages

struct LanguagesSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var query = ""

    private var filtered: [SpokenLanguage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Languages.all }
        return Languages.all.filter { $0.name.localizedStandardContains(q) || $0.code.localizedStandardContains(q) }
    }

    var body: some View {
        PageScroll {
            PageHero(symbol: "globe", color: .teal,
                     title: "Languages",
                     description: "Parakeet automatically detects the language you’re speaking. Select the ones you use — you can switch between them freely.")

            VStack(alignment: .leading, spacing: DS.headerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle("Your Languages")
                    Text(settings.spokenLanguages.count == 1 ? "1 language selected" : "\(settings.spokenLanguages.count) languages selected")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                if filtered.isEmpty {
                    EmptyStateCard(symbol: "magnifyingglass",
                                   title: "No Results",
                                   message: "No languages found for “\(query)”.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 10)], spacing: 10) {
                        ForEach(filtered) { language in
                            LanguageTile(language: language,
                                         isSelected: settings.spokenLanguages.contains(language.code),
                                         isLast: settings.spokenLanguages == [language.code]) {
                                toggle(language)
                            }
                        }
                    }
                }
                Text("At least one language must stay selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Languages")
    }

    private func toggle(_ language: SpokenLanguage) {
        var selected = Set(settings.spokenLanguages)
        if selected.contains(language.code) {
            guard selected.count > 1 else { NSSound.beep(); return }
            selected.remove(language.code)
        } else {
            selected.insert(language.code)
        }
        settings.spokenLanguages = Languages.all.map(\.code).filter(selected.contains)
    }
}

private struct LanguageTile: View {
    let language: SpokenLanguage
    let isSelected: Bool
    let isLast: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(language.flag).font(.system(size: 20))
                Text(language.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color.cardFill))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.55))
                                  : hovering ? AnyShapeStyle(Color.primary.opacity(0.18)) : AnyShapeStyle(Color.cardStroke),
                                  lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isLast ? "At least one language must stay selected" : "")
        .animation(.snappy(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    private var settings = AppSettings.shared
    private var manager = ModelManager.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: "cpu.fill", color: .indigo,
                     title: "Models",
                     description: "Models transcribe your voice right on your Mac, with no internet connection. You only need one.")

            VStack(alignment: .leading, spacing: DS.headerSpacing) {
                SectionTitle("Available")
                VStack(spacing: 12) {
                    ForEach(ModelCatalog.models) { model in
                        ModelCard(model: model)
                            .cardSurface(highlighted: settings.selectedModelID == model.id && manager.isInstalled(model))
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text("Models are stored in Application Support › Flusso › Models.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelManager.modelsDirectory])
                }
                .glassButtonStyle()
                .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 4)
        }
        .onAppear { manager.refresh() }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: "gearshape.fill", color: .gray,
                     title: "General",
                     description: "Startup, pasted text, updates, and information about Flusso.")

            SectionCard(title: "Startup") {
                ToggleRow(symbol: "power", color: .green,
                          title: "Launch at login",
                          subtitle: "Flusso opens in the menu bar when you log in to your Mac.",
                          isOn: $settings.launchAtLogin)
            }

            SectionCard(title: "Text") {
                SettingRow(symbol: "text.cursor", color: .indigo,
                           title: "Insert text by",
                           subtitle: settings.insertionMethod == .paste
                               ? "Pasting is instant and works in almost every app."
                               : "Typing works in apps that block pasting, but long texts take a moment.") {
                    Picker("Insert text by", selection: $settings.insertionMethod) {
                        Text("Pasting").tag(InsertionMethod.paste)
                        Text("Typing").tag(InsertionMethod.type)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if settings.insertionMethod == .paste {
                    RowDivider()
                    ToggleRow(symbol: "doc.on.clipboard.fill", color: .blue,
                              title: "Restore clipboard after pasting",
                              subtitle: "After pasting the transcription, Flusso puts back what was on the clipboard before.",
                              isOn: $settings.restoreClipboard)
                }
                RowDivider()
                ToggleRow(symbol: "space", color: .teal,
                          title: "Add a space after the text",
                          subtitle: "So you can keep typing, or dictate again, right after it.",
                          isOn: $settings.trailingSpace)
                RowDivider()
                ToggleRow(symbol: "scissors", color: .pink,
                          title: "Remove filler words",
                          subtitle: "Removes “uhm”, “ehm”, and similar sounds from the transcribed text.",
                          isOn: $settings.removeFillerWords)
            }

            // Same settings as `UpdateSettingsSection` (AppUpdater.swift), in
            // this page's card style.
            SectionCard(title: "Updates",
                        footer: AppUpdater.isEnabled
                            ? "Flusso checks for a new version at launch and once a day. Automatic updates are installed when you quit the app."
                            : "Development builds don’t update themselves.") {
                ToggleRow(symbol: "arrow.triangle.2.circlepath", color: .blue,
                          title: "Check for updates automatically",
                          isOn: $updater.automaticallyChecks)
                    .disabled(!AppUpdater.isEnabled)
                if updater.allowsAutomaticDownloads {
                    RowDivider()
                    ToggleRow(symbol: "arrow.down.circle.fill", color: .teal,
                              title: "Download and install automatically",
                              isOn: $updater.automaticallyDownloads)
                        .disabled(!updater.automaticallyChecks || !AppUpdater.isEnabled)
                }
                RowDivider()
                SettingRow(symbol: "shippingbox.fill", color: .orange,
                           title: "Version \(updater.versionDescription)") {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .glassButtonStyle()
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            .onAppear { updater.refresh() }

            SectionCard(title: "Welcome") {
                SettingRow(symbol: "sparkles", color: .purple,
                           title: "Show Welcome Again",
                           subtitle: "Go through permissions, model, and shortcuts again.") {
                    Button("Show") { settings.hasCompletedOnboarding = false }
                        .glassButtonStyle()
                }
            }

            AboutCard()
        }
    }
}

private struct AboutCard: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Flusso").font(.headline)
                Text("transcribe.cpp transcription engine · Metal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Free and fully local: your audio and text never leave your Mac.",
                      systemImage: "lock.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardSurface()
    }
}
