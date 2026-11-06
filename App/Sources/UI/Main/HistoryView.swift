import SwiftUI

/// Every saved transcription, as a timeline grouped by day.
struct HistoryView: View {
    private var history = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false
    /// Bumped at midnight so "Oggi"/"Ieri" headings stay correct.
    @State private var dayTick = 0

    private var items: [HistoryItem] { history.displayedItems }

    private var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.text.localizedStandardContains(q) || ($0.appName?.localizedStandardContains(q) ?? false)
        }
    }

    var body: some View {
        let _ = dayTick
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nessuna trascrizione", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Tieni premuto \(AppSettings.shared.holdShortcut.displayString) e parla: le tue dettature appariranno qui.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pageBackground()
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pageBackground()
            } else {
                PageScroll {
                    ForEach(DayGroup.make(filtered)) { group in
                        VStack(alignment: .leading, spacing: DS.headerSpacing) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                SectionTitle(group.title)
                                Text(group.items.count == 1 ? "1 trascrizione" : "\(group.items.count) trascrizioni")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    HistoryRow(item: item)
                                    if item.id != group.items.last?.id {
                                        Divider().padding(.leading, DS.rowHPadding + 56)
                                    }
                                }
                            }
                            .cardSurface()
                        }
                    }
                }
                .animation(.snappy, value: filtered.map(\.id))
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Cerca")
        .toolbar {
            ToolbarItem {
                Button("Cancella tutto", systemImage: "trash") { confirmClear = true }
                    .help("Cancella tutta la cronologia")
                    .disabled(history.items.isEmpty || history.isShowingSamples)
            }
        }
        .onDayChange { dayTick &+= 1 }
        .confirmationDialog("Cancellare tutta la cronologia?", isPresented: $confirmClear) {
            Button("Cancella tutto", role: .destructive) {
                guard !history.isShowingSamples else { return }
                withAnimation { history.clear() }
            }
        } message: {
            Text("Tutte le \(history.items.count) trascrizioni verranno eliminate. L'azione non può essere annullata.")
        }
    }
}

/// Transcriptions of the same calendar day (items are newest first).
private struct DayGroup: Identifiable {
    let id: Date
    let title: String
    let items: [HistoryItem]

    static func make(_ items: [HistoryItem]) -> [DayGroup] {
        let calendar = Calendar.current
        var days: [(Date, [HistoryItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if days.last?.0 == day {
                days[days.count - 1].1.append(item)
            } else {
                days.append((day, [item]))
            }
        }
        return days.map { DayGroup(id: $0.0, title: FlussoFormat.dayTitle($0.0), items: $0.1) }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(FlussoFormat.time(item.date))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
                .help(item.date.formatted(.relative(presentation: .named)))

            VStack(alignment: .leading, spacing: 7) {
                Text(item.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
                HStack(spacing: 10) {
                    if let app = item.appName, !app.isEmpty {
                        AppBadge(name: app)
                    }
                    if item.duration > 0 {
                        Label(FlussoFormat.duration(item.duration), systemImage: "waveform")
                            .labelStyle(.titleAndIcon)
                    }
                    if !item.wasPasted {
                        PillBadge(text: "Non incollato", color: .orange)
                            .help("Non c'era un campo di testo attivo: copia il testo da qui.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                HoverIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copia") { copy() }
                HoverIconButton(symbol: "trash", help: "Elimina", role: .destructive) {
                    withAnimation(.snappy) { HistoryStore.shared.delete(item) }
                }
                .disabled(HistoryStore.shared.isShowingSamples)
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .opacity(hovering || showsHoverControlsAlways ? 1 : 0)
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
        .background(hovering ? Color.rowHover : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copia", systemImage: "doc.on.doc") { copy() }
            Divider()
            Button("Elimina", systemImage: "trash", role: .destructive) {
                withAnimation { HistoryStore.shared.delete(item) }
            }
            .disabled(HistoryStore.shared.isShowingSamples)
        }
    }

    private func copy() {
        HistoryStore.shared.copy(item)
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.snappy) { copied = false }
        }
    }
}
