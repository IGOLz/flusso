import AppKit
import SwiftUI

/// Voice snippets: say a short phrase, get a longer text.
struct SnippetsView: View {
    @Bindable private var settings = AppSettings.shared

    @State private var trigger = ""
    @State private var text = ""
    /// The snippet being edited in the composer, if any.
    @State private var editingID: Snippet.ID?
    @State private var query = ""
    @FocusState private var triggerFocused: Bool

    private var trimmedTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isDuplicate: Bool {
        let key = Snippets.triggerKey(trimmedTrigger)
        return !key.isEmpty && settings.snippets.contains {
            $0.id != editingID && Snippets.triggerKey($0.trigger) == key
        }
    }

    private var canSave: Bool {
        !Snippets.normalizedTrigger(trimmedTrigger).isEmpty && !trimmedText.isEmpty && !isDuplicate
    }

    private var filtered: [Snippet] {
        let all = settings.snippets.sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.trigger.localizedStandardContains(q) || $0.text.localizedStandardContains(q) }
    }

    var body: some View {
        PageScroll {
            PageHero(symbol: "text.bubble.fill", color: .green,
                     title: "Snippets",
                     description: "Say a short phrase and Flusso writes a longer text instead: a link, an address, a signature. It works anywhere in a sentence.")

            composer
            list
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Snippets")
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.headerSpacing) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(editingID == nil ? "New Snippet" : "Edit Snippet")
                Spacer()
                if editingID != nil {
                    Button("Cancel", action: resetComposer)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                    TextField("When you say", text: $trigger,
                              prompt: Text("When you say… e.g. my calendly link"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($triggerFocused)
                    if isDuplicate {
                        Text("Already used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, DS.rowHPadding)
                .padding(.vertical, 12)

                Divider().padding(.leading, DS.rowHPadding + 30)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .padding(.top, 1)
                    TextField("Insert", text: $text, prompt: Text("Insert this text — it can span several lines"),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(3...10)
                    Button(editingID == nil ? "Add" : "Save", action: save)
                        .glassProminentButtonStyle()
                        .disabled(!canSave)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.leading, DS.rowHPadding)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
            }
            .cardSurface(highlighted: editingID != nil)
            .animation(.snappy, value: isDuplicate)

            Text("Press ⌘ Return to save. Snippets are inserted exactly as written; the dictionary doesn’t change them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let count = settings.snippets.count
        VStack(alignment: .leading, spacing: DS.headerSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionTitle("Your Snippets")
                if count > 0 {
                    Text(count == 1 ? "1 snippet" : "\(count) snippets")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            if count == 0 {
                EmptyStateCard(symbol: "text.bubble",
                               title: "No Snippets Yet",
                               message: "Add a phrase and the text it stands for. Then just say it while dictating.")
            } else if filtered.isEmpty {
                EmptyStateCard(symbol: "magnifyingglass",
                               title: "No Results",
                               message: "No snippets found for “\(query)”.")
            } else {
                VStack(spacing: 0) {
                    ForEach(filtered) { snippet in
                        SnippetRow(snippet: snippet, isEditing: snippet.id == editingID,
                                   onEdit: { edit(snippet) }, onDelete: { delete(snippet) })
                        if snippet.id != filtered.last?.id { RowDivider(inset: DS.rowHPadding) }
                    }
                }
                .cardSurface()
                .animation(.snappy, value: filtered)
            }
        }
    }

    // MARK: Actions

    private func save() {
        guard canSave else { return }
        withAnimation(.snappy) {
            if let editingID, let index = settings.snippets.firstIndex(where: { $0.id == editingID }) {
                settings.snippets[index].trigger = trimmedTrigger
                settings.snippets[index].text = text
            } else {
                // The text is kept exactly as written (indentation, line breaks).
                settings.snippets.append(Snippet(trigger: trimmedTrigger, text: text))
            }
        }
        resetComposer()
    }

    private func edit(_ snippet: Snippet) {
        withAnimation(.snappy) {
            editingID = snippet.id
            trigger = snippet.trigger
            text = snippet.text
        }
        triggerFocused = true
    }

    private func delete(_ snippet: Snippet) {
        if snippet.id == editingID { resetComposer() }
        withAnimation(.snappy) { settings.snippets.removeAll { $0.id == snippet.id } }
    }

    private func resetComposer() {
        withAnimation(.snappy) {
            editingID = nil
            trigger = ""
            text = ""
        }
        triggerFocused = true
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text("“\(snippet.trigger)”")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                Text(snippet.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                HoverIconButton(symbol: "pencil", help: "Edit", action: onEdit)
                HoverIconButton(symbol: "trash", help: "Delete", role: .destructive, action: onDelete)
            }
            .opacity(hovering || isEditing || showsHoverControlsAlways ? 1 : 0)
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
        .background(isEditing ? Color.accentColor.opacity(0.08) : hovering ? Color.rowHover : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onEdit)
            Button("Copy Text", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.text, forType: .string)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}
