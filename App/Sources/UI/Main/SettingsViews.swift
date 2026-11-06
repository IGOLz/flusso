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
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(.hold)
                } label: {
                    Text("Tieni premuto per dettare")
                    Text("Tieni premuto, parla e rilascia per incollare il testo.")
                }
                LabeledContent {
                    ShortcutRecorder(.lock)
                } label: {
                    Text("Modalità mani libere")
                    Text("Premi una volta per iniziare a dettare, di nuovo per terminare.")
                }
            } footer: {
                HStack(alignment: .top, spacing: 16) {
                    Text("Fai clic su una scorciatoia e premi la nuova combinazione. Puoi usare anche un solo modificatore, come fn o ⌥ destro.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Ripristina predefiniti") {
                        settings.holdShortcut = .holdDefault
                        settings.lockShortcut = .lockDefault
                    }
                    .disabled(isDefault)
                }
            }

            if usesFn {
                Section {
                    FnKeyTip().padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scorciatoie")
    }
}

// MARK: - Microfono

struct MicrophoneSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private var permissions = Permissions.shared
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDeviceName: String?

    var body: some View {
        Form {
            if permissions.microphone != .granted {
                Section {
                    LabeledContent {
                        Button(permissions.microphone == .denied ? "Apri Impostazioni" : "Consenti") {
                            if permissions.microphone == .denied {
                                permissions.openMicrophoneSettings()
                            } else {
                                Task { await permissions.requestMicrophone() }
                            }
                        }
                    } label: {
                        Label {
                            Text("Accesso al microfono mancante")
                            Text("Consenti a Flusso di usare il microfono per poter dettare.")
                        } icon: {
                            Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section {
                Picker(selection: $settings.microphoneUID) {
                    Text(defaultDeviceName.map { "Predefinito di sistema (\($0))" } ?? "Predefinito di sistema")
                        .tag(String?.none)
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if let uid = settings.microphoneUID, !devices.contains(where: { $0.uid == uid }) {
                        Text("Dispositivo non collegato").tag(Optional(uid))
                    }
                } label: {
                    Text("Microfono")
                    Text("Il dispositivo da cui Flusso registra la tua voce.")
                }
            }

            Section {
                Toggle(isOn: $settings.instantStart) {
                    Text("Avvio istantaneo")
                    Text("Il microfono resta pronto, così la registrazione parte in 0 ms e viene catturato anche l'istante prima della pressione del tasto. Mentre è attivo, macOS mostra l'indicatore arancione del microfono.")
                }
                Toggle(isOn: $settings.playSounds) {
                    Text("Suoni")
                    Text("Riproduci un suono quando la registrazione inizia e finisce.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Microfono")
        .task { reloadDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadDevices()
        }
    }

    private func reloadDevices() {
        let list = AudioDevices.inputDevices()
        devices = list
        let defaultID = AudioDevices.defaultInputDeviceID()
        defaultDeviceName = list.first { $0.id == defaultID }?.name
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
        Form {
            Section {
                Label {
                    Text("Parakeet riconosce automaticamente la lingua in cui parli: seleziona quelle che usi. Puoi passare da una all'altra liberamente.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                }
            }

            Section {
                if filtered.isEmpty {
                    Text("Nessuna lingua trovata per «\(query)».")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { language in
                    LanguageRow(language: language,
                                isSelected: settings.spokenLanguages.contains(language.code),
                                isLast: settings.spokenLanguages == [language.code]) {
                        toggle(language)
                    }
                }
            } header: {
                Text(settings.spokenLanguages.count == 1 ? "1 lingua selezionata" : "\(settings.spokenLanguages.count) lingue selezionate")
            } footer: {
                Text("Almeno una lingua deve restare selezionata.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lingue")
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

private struct LanguageRow: View {
    let language: SpokenLanguage
    let isSelected: Bool
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(language.flag).font(.title3)
                Text(language.name)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isLast ? "Almeno una lingua deve restare selezionata" : "")
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Modelli

struct ModelsSettingsView: View {
    private var settings = AppSettings.shared
    private var manager = ModelManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("I modelli trascrivono la tua voce direttamente sul Mac, senza connessione. Ne basta uno.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(ModelCatalog.models) { model in
                    ModelCard(model: model)
                        .card(highlighted: settings.selectedModelID == model.id && manager.isInstalled(model))
                }

                HStack {
                    Text("I modelli sono salvati in Application Support › Flusso › Models.")
                    Spacer()
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ModelManager.modelsDirectory])
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Modelli")
        .onAppear { manager.refresh() }
    }
}

// MARK: - Generali

struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    Text("Avvia al login")
                    Text("Flusso si apre nella barra dei menu quando accedi al Mac.")
                }
            }

            Section("Testo") {
                Toggle(isOn: $settings.restoreClipboard) {
                    Text("Ripristina appunti dopo l'incolla")
                    Text("Dopo aver incollato la trascrizione, Flusso rimette negli appunti quello che c'era prima.")
                }
                Toggle(isOn: $settings.removeFillerWords) {
                    Text("Rimuovi intercalari")
                    Text("Elimina «ehm», «uhm» e simili dal testo trascritto.")
                }
            }

            Section {
                LabeledContent {
                    Button("Mostra") { settings.hasCompletedOnboarding = false }
                } label: {
                    Text("Mostra di nuovo l'introduzione")
                    Text("Ripercorri permessi, modello e scorciatoie.")
                }
            }

            Section {
                LabeledContent("Versione", value: AppInfo.version)
                LabeledContent("Motore", value: "transcribe.cpp · Metal")
            } footer: {
                Text("Flusso è gratuito e funziona interamente in locale: audio e testo non lasciano mai il tuo Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Generali")
    }
}
