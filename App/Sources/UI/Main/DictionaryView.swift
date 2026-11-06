import SwiftUI

/// The user's dictionary: names, brands and jargon Flusso must spell right.
struct DictionaryView: View {
    @Bindable private var settings = AppSettings.shared

    @State private var newTerm = ""
    @State private var newSpokenAs = ""
    @State private var showSpokenAs = false
    @State private var query = ""
    @State private var sample = ""
    @FocusState private var termFocused: Bool

    private var filtered: [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = settings.dictionary.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter { $0.term.localizedStandardContains(q) || ($0.spokenAs ?? "").localizedStandardContains(q) }
    }

    private var trimmedTerm: String { newTerm.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isDuplicate: Bool {
        settings.dictionary.contains { $0.term.caseInsensitiveCompare(trimmedTerm) == .orderedSame }
    }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Aggiungi nomi, marchi e termini tecnici: dopo ogni dettatura Flusso corregge le parole che suonano o si scrivono in modo simile, così vengono sempre scritte come le hai inserite.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "character.book.closed").foregroundStyle(.tint)
                }
            }

            Section("Aggiungi una parola") {
                TextField("Parola o nome", text: $newTerm, prompt: Text("es. Flusso, SwiftUI, Craciun"))
                    .focused($termFocused)
                    .onSubmit(add)
                if showSpokenAs {
                    TextField("Il modello la scrive come", text: $newSpokenAs, prompt: Text("es. suift ui"))
                        .onSubmit(add)
                }
                HStack {
                    Toggle("Correggi una trascrizione specifica", isOn: $showSpokenAs.animation())
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .help("Per parole molto diverse da come le trascrive il modello: indica cosa scrive, verrà sempre sostituito.")
                    Spacer()
                    if isDuplicate {
                        Text("Già nel dizionario").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Aggiungi", action: add)
                        .glassProminentButtonStyle()
                        .disabled(trimmedTerm.isEmpty || isDuplicate)
                }
            }

            Section {
                if settings.dictionary.isEmpty {
                    Text("Nessuna parola ancora. Le parole che aggiungi compaiono qui.")
                        .foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("Nessuna parola trovata per «\(query)».")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered) { entry in
                    DictionaryRow(entry: entry) { remove(entry) }
                }
            } header: {
                Text(settings.dictionary.count == 1 ? "1 parola" : "\(settings.dictionary.count) parole")
            }

            if !settings.dictionary.isEmpty {
                Section {
                    TextField("Frase di prova", text: $sample,
                              prompt: Text("Scrivi una frase come la trascriverebbe il modello"))
                    if !sample.isEmpty {
                        LabeledContent("Risultato") {
                            Text(CustomDictionary.apply(sample, entries: settings.dictionary))
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Prova")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dizionario")
        .searchable(text: $query, placement: .toolbar, prompt: "Cerca nel dizionario")
    }

    private func add() {
        let term = trimmedTerm
        guard !term.isEmpty, !isDuplicate else { return }
        let spoken = newSpokenAs.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.dictionary.append(DictionaryEntry(term: term, spokenAs: showSpokenAs && !spoken.isEmpty ? spoken : nil))
        newTerm = ""
        newSpokenAs = ""
        termFocused = true
    }

    private func remove(_ entry: DictionaryEntry) {
        settings.dictionary.removeAll { $0.id == entry.id }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term).font(.body.weight(.medium))
                if let spoken = entry.spokenAs {
                    Text("sostituisce «\(spoken)»")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
            .help("Rimuovi dal dizionario")
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copia") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.term, forType: .string)
            }
            Button("Rimuovi", role: .destructive, action: onDelete)
        }
    }
}
