import SwiftUI

struct HomeView: View {
    @Binding var selection: SidebarPage?

    private var settings = AppSettings.shared
    private var controller = AppController.shared
    private var permissions = Permissions.shared
    private var history = HistoryStore.shared

    init(selection: Binding<SidebarPage?>) {
        _selection = selection
    }

    private var selectedModel: ModelInfo? {
        ModelCatalog.model(id: settings.selectedModelID)
    }

    var body: some View {
        Form {
            Section {
                header
                if permissions.microphone != .granted {
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
                            Text("Flusso non può registrare la tua voce.")
                        } icon: {
                            Image(systemName: "mic.slash.fill").foregroundStyle(.orange)
                        }
                    }
                }
                if !permissions.accessibility {
                    LabeledContent {
                        Button("Apri Impostazioni") {
                            permissions.requestAccessibility()
                            permissions.openAccessibilitySettings()
                        }
                    } label: {
                        Label {
                            Text("Permesso Accessibilità mancante")
                            Text("Serve per la scorciatoia globale e per incollare il testo.")
                        } icon: {
                            Image(systemName: "accessibility").foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section("Come si usa") {
                LabeledContent {
                    KeyCaps(settings.holdShortcut)
                } label: {
                    Text("Tieni premuto per dettare")
                    Text("Parla e rilascia: il testo viene incollato dove stai scrivendo.")
                }
                LabeledContent {
                    KeyCaps(settings.lockShortcut)
                } label: {
                    Text("Modalità mani libere")
                    Text("Premi una volta per iniziare, di nuovo per terminare.")
                }
            }

            Section("Statistiche") {
                HStack(spacing: 0) {
                    Stat(value: history.totalWords, title: "parole dettate", symbol: "text.word.spacing")
                    Divider().frame(height: 40)
                    Stat(value: history.items.count, title: "trascrizioni", symbol: "waveform")
                }
                .padding(.vertical, 4)
            }

            Section {
                if let latest = history.items.first {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(latest.text)
                            .textSelection(.enabled)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(latest.date, format: .relative(presentation: .named))
                            if let app = latest.appName {
                                Text("·")
                                Text(app)
                            }
                            if !latest.wasPasted {
                                PillBadge(text: "Non incollato", color: .orange)
                            }
                            Spacer()
                            TextCopyButton(text: latest.text, title: "Copia")
                                .glassButtonStyle()
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("Le tue dettature appariranno qui.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Ultima trascrizione")
                    Spacer()
                    if !history.items.isEmpty {
                        Button("Mostra tutte") { selection = .history }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home")
    }

    // MARK: Status header

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Flusso").font(.title2.weight(.bold))
                status
            }
            Spacer()
            statusAction
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            switch (controller.phase, controller.engineStatus) {
            case (.recording, _):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("In ascolto…")
            case (.transcribing, _):
                ProgressView().controlSize(.mini)
                Text("Trascrizione in corso…")
            case (_, .ready):
                Circle().fill(permissions.allGranted ? .green : .orange).frame(width: 8, height: 8)
                Text(permissions.allGranted ? "Pronto" : "Modello pronto, permessi mancanti")
                if let selectedModel {
                    Text("· \(selectedModel.name)")
                }
            case (_, .loading):
                ProgressView().controlSize(.mini)
                Text("Caricamento di \(selectedModel?.name ?? "modello")…")
            case (_, .noModel):
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("Nessun modello installato")
            case (_, .failed(let message)):
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(message).lineLimit(2)
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusAction: some View {
        switch controller.engineStatus {
        case .noModel:
            Button("Scarica un modello") { selection = .models }
                .glassProminentButtonStyle()
        case .failed:
            Button("Riprova") {
                if let selectedModel { controller.selectModel(selectedModel) }
            }
            .glassButtonStyle()
        default:
            EmptyView()
        }
    }
}

private struct Stat: View {
    let value: Int
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
