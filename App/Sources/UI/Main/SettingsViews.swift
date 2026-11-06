import AppKit
import SwiftUI

// MARK: - Scorciatoie

struct ShortcutsSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    private var usesFn: Bool {
        settings.holdShortcut.modifiers.contains(.function) || settings.lockShortcut.modifiers.contains(.function)
    }

    private var isDefault: Bool {
        settings.holdShortcut == .holdDefault && settings.lockShortcut == .lockDefault
    }

    var body: some View {
        PageScroll {
            PageHero(symbol: "keyboard.fill", color: .gray,
                     title: "Scorciatoie",
                     description: "Premi le scorciatoie per provarle: i tasti si illuminano. Fai clic su una scorciatoia per registrarne una nuova.")

            SectionCard(title: "Dettatura",
                        footer: "Puoi usare anche un solo modificatore, come fn o ⌥ destro. Esc annulla la registrazione.") {
                SettingRow(symbol: "mic.fill", color: .orange,
                           title: "Tieni premuto per dettare",
                           subtitle: "Tieni premuto, parla e rilascia per incollare il testo.") {
                    ShortcutRecorder(.hold)
                }
                RowDivider()
                SettingRow(symbol: "lock.fill", color: .blue,
                           title: "Modalità mani libere",
                           subtitle: "Premi una volta per iniziare a dettare, di nuovo per terminare.") {
                    ShortcutRecorder(.lock)
                }
            } accessory: {
                Button("Ripristina predefiniti") {
                    withAnimation(.snappy) {
                        settings.holdShortcut = .holdDefault
                        settings.lockShortcut = .lockDefault
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

// MARK: - Microfono

struct MicrophoneSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private var permissions = Permissions.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDeviceName: String?

    var body: some View {
        PageScroll {
            PageHero(symbol: "mic.fill", color: .pink,
                     title: "Microfono",
                     description: "Scegli da quale dispositivo Flusso registra la tua voce e come si comporta durante la registrazione.")

            if permissions.microphone != .granted {
                NoticeCard(symbol: "mic.slash.fill",
                           title: "Accesso al microfono mancante",
                           message: "Consenti a Flusso di usare il microfono per poter dettare.") {
                    Button(permissions.microphone == .denied ? "Apri Impostazioni" : "Consenti") {
                        if permissions.microphone == .denied {
                            permissions.openMicrophoneSettings()
                        } else {
                            Task { await permissions.requestMicrophone() }
                        }
                    }
                    .glassButtonStyle()
                }
            }

            SectionCard(title: "Dispositivo di ingresso") {
                DeviceRow(symbol: "gearshape.fill", color: .gray,
                          title: "Predefinito di sistema",
                          subtitle: defaultDeviceName ?? "Segue le Impostazioni di Sistema",
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
                              title: "Dispositivo non collegato",
                              subtitle: "Collegalo di nuovo o scegline un altro.",
                              isSelected: true) {}
                }
            }

            SectionCard(title: "Registrazione") {
                ToggleRow(symbol: "bolt.fill", color: .orange,
                          title: "Avvio istantaneo",
                          subtitle: "Il microfono resta pronto, così la registrazione parte in 0 ms e viene catturato anche l'istante prima della pressione del tasto. Mentre è attivo, macOS mostra l'indicatore arancione del microfono.",
                          isOn: $settings.instantStart)
                RowDivider()
                ToggleRow(symbol: "speaker.wave.2.fill", color: .blue,
                          title: "Suoni",
                          subtitle: "Riproduci un suono quando la registrazione inizia e finisce.",
                          isOn: $settings.playSounds)
            }
        }
        .task { reloadDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadDevices()
        }
    }

    private static func symbol(for name: String) -> String {
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

// MARK: - Lingue

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
                     title: "Lingue",
                     description: "Parakeet riconosce automaticamente la lingua in cui parli: seleziona quelle che usi. Puoi passare da una all'altra liberamente.")

            VStack(alignment: .leading, spacing: DS.headerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionTitle("Le tue lingue")
                    Text(settings.spokenLanguages.count == 1 ? "1 selezionata" : "\(settings.spokenLanguages.count) selezionate")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                if filtered.isEmpty {
                    EmptyStateCard(symbol: "magnifyingglass",
                                   title: "Nessun risultato",
                                   message: "Nessuna lingua trovata per «\(query)».")
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
                Text("Almeno una lingua deve restare selezionata.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Cerca lingua")
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
        .help(isLast ? "Almeno una lingua deve restare selezionata" : "")
        .animation(.snappy(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Modelli

struct ModelsSettingsView: View {
    private var settings = AppSettings.shared
    private var manager = ModelManager.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: "cpu.fill", color: .indigo,
                     title: "Modelli",
                     description: "I modelli trascrivono la tua voce direttamente sul Mac, senza connessione. Ne basta uno.")

            VStack(alignment: .leading, spacing: DS.headerSpacing) {
                SectionTitle("Disponibili")
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
                Text("I modelli sono salvati in Application Support › Flusso › Models.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mostra nel Finder") {
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

// MARK: - Generali

struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        PageScroll {
            PageHero(symbol: "gearshape.fill", color: .gray,
                     title: "Generali",
                     description: "Avvio, testo incollato, aggiornamenti e informazioni su Flusso.")

            SectionCard(title: "Avvio") {
                ToggleRow(symbol: "power", color: .green,
                          title: "Avvia al login",
                          subtitle: "Flusso si apre nella barra dei menu quando accedi al Mac.",
                          isOn: $settings.launchAtLogin)
            }

            SectionCard(title: "Testo") {
                ToggleRow(symbol: "doc.on.clipboard.fill", color: .blue,
                          title: "Ripristina appunti dopo l'incolla",
                          subtitle: "Dopo aver incollato la trascrizione, Flusso rimette negli appunti quello che c'era prima.",
                          isOn: $settings.restoreClipboard)
                RowDivider()
                ToggleRow(symbol: "scissors", color: .pink,
                          title: "Rimuovi intercalari",
                          subtitle: "Elimina «ehm», «uhm» e simili dal testo trascritto.",
                          isOn: $settings.removeFillerWords)
            }

            // Same settings as `UpdateSettingsSection` (AppUpdater.swift), in
            // this page's card style.
            SectionCard(title: "Aggiornamenti",
                        footer: AppUpdater.isEnabled
                            ? "Flusso cerca una nuova versione all'avvio e una volta al giorno. Gli aggiornamenti automatici vengono installati alla chiusura dell'app."
                            : "Le build di sviluppo non si aggiornano da sole.") {
                ToggleRow(symbol: "arrow.triangle.2.circlepath", color: .blue,
                          title: "Cerca aggiornamenti automaticamente",
                          isOn: $updater.automaticallyChecks)
                    .disabled(!AppUpdater.isEnabled)
                if updater.allowsAutomaticDownloads {
                    RowDivider()
                    ToggleRow(symbol: "arrow.down.circle.fill", color: .teal,
                              title: "Scarica e installa automaticamente",
                              isOn: $updater.automaticallyDownloads)
                        .disabled(!updater.automaticallyChecks || !AppUpdater.isEnabled)
                }
                RowDivider()
                SettingRow(symbol: "shippingbox.fill", color: .orange,
                           title: "Versione \(updater.versionDescription)") {
                    Button("Verifica aggiornamenti…") { updater.checkForUpdates() }
                        .glassButtonStyle()
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            .onAppear { updater.refresh() }

            SectionCard(title: "Introduzione") {
                SettingRow(symbol: "sparkles", color: .purple,
                           title: "Mostra di nuovo l'introduzione",
                           subtitle: "Ripercorri permessi, modello e scorciatoie.") {
                    Button("Mostra") { settings.hasCompletedOnboarding = false }
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
                Text("Motore di trascrizione transcribe.cpp · Metal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Gratuito e interamente in locale: audio e testo non lasciano mai il tuo Mac.",
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
