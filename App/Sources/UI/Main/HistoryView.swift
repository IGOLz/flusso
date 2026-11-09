import SwiftUI
import UniformTypeIdentifiers

/// Every saved transcription, as a timeline grouped by day.
struct HistoryView: View {
    private var history = HistoryStore.shared
    @State private var query = ""
    @State private var confirmClear = false
    /// Bumped at midnight so "Today"/"Yesterday" headings stay correct.
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
                    Label("No Transcriptions Yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Hold \(AppSettings.shared.holdShortcut.displayString) and speak — your dictations will appear here.")
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
                                Text(group.items.count == 1 ? "1 transcription" : "\(group.items.count) transcriptions")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    HistoryRow(item: item)
                                    if item.id != group.items.last?.id {
                                        Divider().padding(.leading, DS.rowHPadding + 76)
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
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Button("Clear All", systemImage: "trash") { confirmClear = true }
                    .help("Clear all history")
                    .disabled(history.items.isEmpty || history.isShowingSamples)
            }
        }
        .onDayChange { dayTick &+= 1 }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear All", role: .destructive) {
                guard !history.isShowingSamples else { return }
                AudioPlayback.shared.stop()
                withAnimation { history.clear() }
            }
        } message: {
            Text(history.items.count == 1
                 ? "Your 1 transcription will be deleted. This can’t be undone."
                 : "All \(history.items.count.formatted(.number.locale(FlussoFormat.locale))) transcriptions will be deleted. This can’t be undone.")
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
    @State private var audioError: String?
    private var playback = AudioPlayback.shared
    private var controller = AppController.shared

    init(item: HistoryItem) { self.item = item }

    private var isPlaying: Bool { playback.playingID == item.id }
    private var isRetranscribing: Bool { controller.retranscribing.contains(item.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(FlussoFormat.time(item.date))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .help(item.date.formatted(FlussoFormat.relative))

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
                        PillBadge(text: "Not pasted", color: .orange)
                            .help("No text field was active — copy the text from here.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                if item.audioFile != nil {
                    HoverIconButton(symbol: isPlaying ? "stop.fill" : "play.fill",
                                    help: isPlaying ? "Stop" : "Play Recording") { playback.toggle(item) }
                    HoverIconButton(symbol: "square.and.arrow.down", help: "Save Recording…") { saveRecording() }
                        .disabled(HistoryStore.shared.isShowingSamples)
                    if isRetranscribing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 26, height: 26)
                            .help("Transcribing…")
                    } else {
                        HoverIconButton(symbol: "arrow.clockwise",
                                        help: "Transcribe Again (with the current model and settings)") { retranscribe() }
                            .disabled(HistoryStore.shared.isShowingSamples || !controller.retranscribing.isEmpty)
                    }
                }
                HoverIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
                HoverIconButton(symbol: "trash", help: "Delete", role: .destructive) { delete() }
                    .disabled(HistoryStore.shared.isShowingSamples)
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .opacity(hovering || isPlaying || isRetranscribing || showsHoverControlsAlways ? 1 : 0)
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
        .background(hovering ? Color.rowHover : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
            if item.audioFile != nil {
                Button(isPlaying ? "Stop" : "Play Recording", systemImage: isPlaying ? "stop.fill" : "play.fill") {
                    playback.toggle(item)
                }
                Button("Transcribe Again", systemImage: "arrow.clockwise") { retranscribe() }
                    .disabled(!controller.retranscribing.isEmpty || HistoryStore.shared.isShowingSamples)
                Button("Save Recording…", systemImage: "square.and.arrow.down") { saveRecording() }
                    .disabled(HistoryStore.shared.isShowingSamples)
                Button("Show in Finder", systemImage: "folder") { showRecording() }
                    .disabled(HistoryStore.shared.isShowingSamples)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { delete() }
                .disabled(HistoryStore.shared.isShowingSamples)
        }
        .alert("Couldn't Access Recording", isPresented: Binding(
            get: { audioError != nil },
            set: { if !$0 { audioError = nil } }
        )) {
            Button("OK", role: .cancel) { audioError = nil }
        } message: {
            Text(audioError ?? "")
        }
    }

    private func saveRecording() {
        guard let fileName = item.audioFile else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Flusso-\(date.string(from: item.date)).wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let audio = try Data(contentsOf: HistoryAudio.url(for: fileName))
            try audio.write(to: destination, options: .atomic)
        } catch {
            audioError = error.localizedDescription
        }
    }

    private func showRecording() {
        guard let fileName = item.audioFile else { return }
        let url = HistoryAudio.url(for: fileName)
        do {
            guard try url.checkResourceIsReachable() else { throw CocoaError(.fileNoSuchFile) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            audioError = error.localizedDescription
        }
    }

    private func retranscribe() {
        Task { await controller.retranscribe(item) }
    }

    private func delete() {
        if isPlaying { playback.stop() }
        withAnimation(.snappy) { HistoryStore.shared.delete(item) }
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
