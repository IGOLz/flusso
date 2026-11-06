import SwiftUI

struct HistoryView: View {
    private var history = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history.items }
        return history.items.filter {
            $0.text.localizedStandardContains(q) || ($0.appName?.localizedStandardContains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if history.items.isEmpty {
                ContentUnavailableView {
                    Label("Nessuna trascrizione", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Tieni premuto \(AppSettings.shared.holdShortcut.displayString) e parla: le tue dettature appariranno qui.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(filtered) { item in
                        HistoryRow(item: item)
                            .contextMenu {
                                Button("Copia", systemImage: "doc.on.doc") { history.copy(item) }
                                Divider()
                                Button("Elimina", systemImage: "trash", role: .destructive) {
                                    withAnimation { history.delete(item) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Cronologia")
        .searchable(text: $query, placement: .toolbar, prompt: "Cerca")
        .toolbar {
            ToolbarItem {
                Button("Cancella tutto", systemImage: "trash") { confirmClear = true }
                    .help("Cancella tutta la cronologia")
                    .disabled(history.items.isEmpty)
            }
        }
        .confirmationDialog("Cancellare tutta la cronologia?", isPresented: $confirmClear) {
            Button("Cancella tutto", role: .destructive) {
                withAnimation { history.clear() }
            }
        } message: {
            Text("Tutte le \(history.items.count) trascrizioni verranno eliminate. L'azione non può essere annullata.")
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(item.date, format: .relative(presentation: .named))
                    if let app = item.appName, !app.isEmpty {
                        Text("·")
                        Text(app)
                    }
                    if item.duration > 0 {
                        Text("·")
                        Text(Duration.seconds(item.duration), format: .units(allowed: [.minutes, .seconds], width: .narrow))
                    }
                    if !item.wasPasted {
                        PillBadge(text: "Non incollato", color: .orange)
                            .help("Non c'era un campo di testo attivo: copia il testo da qui.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextCopyButton(text: item.text)
                .buttonStyle(.borderless)
                .controlSize(.large)
        }
        .padding(.vertical, 6)
    }
}
