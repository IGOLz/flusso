import SwiftUI

/// A transcription model with its download state and actions.
struct ModelCard: View {
    let model: ModelInfo
    /// In onboarding the card selects the model automatically once installed
    /// and hides the "use"/"delete" actions.
    var compact = false

    private var settings = AppSettings.shared
    private var manager = ModelManager.shared

    init(model: ModelInfo, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    private var isSelected: Bool { settings.selectedModelID == model.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemName: "waveform", color: model.isRecommended ? .indigo : .gray, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name).font(.title3.weight(.semibold))
                        if model.isRecommended {
                            PillBadge(text: "Consigliato", color: .accentColor, systemImage: "star.fill")
                        }
                        if isSelected && !compact && manager.isInstalled(model) {
                            PillBadge(text: "In uso", color: .green, systemImage: "checkmark")
                        }
                    }
                    Text(model.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Label(model.sizeDescription, systemImage: "internaldrive")
                        Label(model.languages, systemImage: "globe")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            ModelActions(model: model, compact: compact)
        }
        .padding(18)
    }
}

/// State-specific controls: download / progress / verify / use / delete / retry.
struct ModelActions: View {
    let model: ModelInfo
    var compact = false

    private var settings = AppSettings.shared
    private var manager = ModelManager.shared
    @State private var confirmDelete = false

    init(model: ModelInfo, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    private var isSelected: Bool { settings.selectedModelID == model.id }

    var body: some View {
        Group {
            switch manager.state(for: model) {
            case .notDownloaded:
                HStack {
                    Text("Non scaricato").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        manager.download(model)
                    } label: {
                        Label("Scarica", systemImage: "arrow.down")
                    }
                    .glassProminentButtonStyle()
                }

            case .downloading(let progress, let received, let total):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                    HStack {
                        Text("\(ByteFormat.string(received)) di \(ByteFormat.string(total))")
                            .monospacedDigit()
                        Text("·")
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                        Spacer()
                        Button("Annulla") { manager.cancelDownload(model) }
                            .glassButtonStyle()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

            case .verifying:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: 1)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Verifica dell'integrità del file…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

            case .downloaded:
                HStack(spacing: 10) {
                    Label("Scaricato", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                    Spacer()
                    if !compact {
                        if isSelected {
                            Text("Modello in uso").foregroundStyle(.secondary).font(.callout)
                        } else {
                            Button("Elimina", role: .destructive) { confirmDelete = true }
                                .glassButtonStyle()
                            Button("Usa questo modello") { AppController.shared.selectModel(model) }
                                .glassProminentButtonStyle()
                        }
                    }
                }

            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        manager.download(model)
                    } label: {
                        Label("Riprova", systemImage: "arrow.clockwise")
                    }
                    .glassProminentButtonStyle()
                }
            }
        }
        .animation(.snappy, value: manager.state(for: model))
        .onChange(of: manager.state(for: model)) { old, new in
            // Onboarding: as soon as the recommended model lands on disk, use it.
            if compact, new == .downloaded, old != .downloaded {
                AppController.shared.selectModel(model)
            }
        }
        .confirmationDialog("Eliminare \(model.name)?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) { manager.delete(model) }
        } message: {
            Text("Libererai \(model.sizeDescription). Potrai scaricarlo di nuovo in qualsiasi momento.")
        }
    }
}
