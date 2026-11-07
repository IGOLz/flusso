import AppKit
import SwiftUI

/// The user's dictionary: names, brands and jargon Flusso must spell right.
struct DictionaryView: View {
    @Bindable private var settings = AppSettings.shared
    #if DEBUG
    @State private var sampleEntries = DebugSample.dictionary
    #endif

    @State private var newTerm = ""
    @State private var newSpokenAs = ""
    @State private var showSpokenAs = false
    @State private var query = ""
    @State private var sample = ""
    @FocusState private var termFocused: Bool

    /// The saved dictionary (in-memory sample data in DEBUG screenshots).
    private var entries: Binding<[DictionaryEntry]> {
        #if DEBUG
        if DebugSample.isEnabled { return $sampleEntries }
        #endif
        return $settings.dictionary
    }

    private var filtered: [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = entries.wrappedValue.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter { $0.term.localizedStandardContains(q) || ($0.spokenAs ?? "").localizedStandardContains(q) }
    }

    private var trimmedTerm: String { newTerm.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isDuplicate: Bool {
        entries.wrappedValue.contains { $0.term.caseInsensitiveCompare(trimmedTerm) == .orderedSame }
    }

    var body: some View {
        PageScroll {
            PageHero(symbol: "character.book.closed.fill", color: .purple,
                     title: "Your Dictionary",
                     description: "Names, brands, and technical terms that should always be spelled your way. After each dictation, Flusso corrects words that sound or are spelled similarly.")

            composer

            wordsSection

            if !entries.wrappedValue.isEmpty {
                tester
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Dictionary")
    }

    // MARK: Add

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.headerSpacing) {
            SectionTitle("Add a Word")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tint)
                    TextField("Word or name", text: $newTerm,
                              prompt: Text("A word, name, or brand — e.g. Flusso, SwiftUI, Craciun"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($termFocused)
                        .onSubmit(add)
                    if isDuplicate {
                        Text("Already in dictionary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Button("Add", action: add)
                        .glassProminentButtonStyle()
                        .disabled(trimmedTerm.isEmpty || isDuplicate)
                }
                .padding(.leading, DS.rowHPadding)
                .padding(.trailing, 10)
                .padding(.vertical, 10)

                if showSpokenAs {
                    Divider().padding(.leading, DS.rowHPadding + 28)
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.left.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        TextField("The model writes it as", text: $newSpokenAs,
                                  prompt: Text("How the model writes it — e.g. swift you eye"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .onSubmit(add)
                    }
                    .padding(.horizontal, DS.rowHPadding)
                    .padding(.vertical, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .cardSurface()
            .animation(.snappy, value: isDuplicate)

            Toggle("Correct a specific transcription", isOn: $showSpokenAs.animation(.snappy))
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("For words the model writes very differently: enter what it writes and it will always be replaced.")
                .padding(.leading, 4)
        }
    }

    // MARK: Words

    @ViewBuilder
    private var wordsSection: some View {
        let count = entries.wrappedValue.count
        VStack(alignment: .leading, spacing: DS.headerSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionTitle("Your Words")
                if count > 0 {
                    Text(count == 1 ? "1 word" : "\(count) words")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            if count == 0 {
                EmptyStateCard(symbol: "character.book.closed",
                               title: "No Words Yet",
                               message: "Words you add appear here, ready to be recognized in every dictation.")
            } else if filtered.isEmpty {
                EmptyStateCard(symbol: "magnifyingglass",
                               title: "No Results",
                               message: "No words found for “\(query)”.")
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(filtered) { entry in
                        WordChip(entry: entry) { remove(entry) }
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                .animation(.snappy, value: filtered.map(\.id))
            }
        }
    }

    // MARK: Try it

    private var tester: some View {
        SectionCard(title: "Try It",
                    footer: "Type a sentence the way the model would transcribe it to see how the dictionary corrects it.") {
            HStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Test sentence", text: $sample,
                          prompt: Text("e.g. I rebuilt the app in swift you eye"))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, DS.rowHPadding)
            .padding(.vertical, 12)
            if !sample.isEmpty {
                Divider().padding(.leading, DS.rowHPadding + 28)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .frame(width: 18)
                    Text(CustomDictionary.apply(sample, entries: entries.wrappedValue))
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.rowHPadding)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: sample.isEmpty)
    }

    // MARK: Actions

    private func add() {
        let term = trimmedTerm
        guard !term.isEmpty, !isDuplicate else { return }
        let spoken = newSpokenAs.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.snappy) {
            entries.wrappedValue.append(DictionaryEntry(term: term, spokenAs: showSpokenAs && !spoken.isEmpty ? spoken : nil))
        }
        newTerm = ""
        newSpokenAs = ""
        termFocused = true
    }

    private func remove(_ entry: DictionaryEntry) {
        withAnimation(.snappy) {
            entries.wrappedValue.removeAll { $0.id == entry.id }
        }
    }
}

/// A dictionary word as a removable tag.
private struct WordChip: View {
    let entry: DictionaryEntry
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Long words truncate instead of pushing the remove button out of the card.
            Text(entry.term)
                .fontWeight(.medium)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
                .help(entry.term)
            if let spoken = entry.spokenAs {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 9, weight: .bold))
                    Text(spoken)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Replaces “\(spoken)”")
            }
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help("Remove from Dictionary")
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(hovering ? 0.16 : 0.1), in: .capsule)
        .overlay {
            Capsule().strokeBorder(Color.accentColor.opacity(hovering ? 0.35 : 0.18), lineWidth: 1)
        }
        .contentShape(.capsule)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.term, forType: .string)
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}
