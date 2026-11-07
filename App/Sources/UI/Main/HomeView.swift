import SwiftUI

/// Dashboard: status, stats, weekly activity, shortcuts and latest dictations.
struct HomeView: View {
    @Binding var selection: SidebarPage?

    private var settings = AppSettings.shared
    private var controller = AppController.shared
    private var permissions = Permissions.shared
    private var history = HistoryStore.shared
    /// Bumped at midnight so "today", the streak and the week chart stay correct.
    @State private var dayTick = 0

    init(selection: Binding<SidebarPage?>) {
        _selection = selection
    }

    var body: some View {
        let _ = dayTick
        let items = history.displayedItems
        let stats = history.isShowingSamples ? DictationStats(items: items)
            : DictationStats(days: StatsStore.shared.byDay())
        PageScroll {
            WelcomeHeader(selection: $selection)

            if permissions.microphone != .granted || !permissions.accessibility {
                VStack(spacing: 10) {
                    if permissions.microphone != .granted {
                        NoticeCard(symbol: "mic.slash.fill",
                                   title: "Microphone access needed",
                                   message: "Flusso can’t record your voice.") {
                            Button(permissions.microphone == .denied ? "Open Settings" : "Allow") {
                                if permissions.microphone == .denied {
                                    permissions.openMicrophoneSettings()
                                } else {
                                    Task { await permissions.requestMicrophone() }
                                }
                            }
                            .glassButtonStyle()
                        }
                    }
                    if !permissions.accessibility {
                        NoticeCard(symbol: "accessibility",
                                   title: "Accessibility permission needed",
                                   message: "Required for the global shortcut and to paste text.") {
                            Button("Open Settings") {
                                permissions.requestAccessibility()
                                permissions.openAccessibilitySettings()
                            }
                            .glassButtonStyle()
                        }
                    }
                }
            }

            AdaptiveColumns(minColumnWidth: 165) {
                StatCard(symbol: "text.bubble.fill", color: .blue,
                         value: stats.words.formatted(.number.locale(FlussoFormat.locale)),
                         unit: nil,
                         title: "Words dictated",
                         caption: stats.transcriptions == 1 ? "in 1 transcription"
                             : "in \(stats.transcriptions.formatted(.number.locale(FlussoFormat.locale))) transcriptions")
                let saved = FlussoFormat.savedTime(stats.savedSeconds)
                StatCard(symbol: "bolt.fill", color: .orange,
                         value: saved.value, unit: saved.unit,
                         title: "Time saved",
                         caption: "vs. typing at \(Int(DictationStats.typingWPM)) words/min")
                StatCard(symbol: "flame.fill", color: .pink,
                         value: "\(stats.streak)", unit: stats.streak == 1 ? "day" : "days",
                         title: "Streak",
                         caption: stats.streak == 0 ? "Dictate today to start one"
                             : stats.dictatedToday ? "in a row, including today" : "Dictate today to keep it going")
            }

            AdaptiveColumns(minColumnWidth: 270) {
                WeekActivityCard(week: stats.week, wordsPerMinute: stats.wordsPerMinute)
                ShortcutsCard { selection = .shortcuts }
            }

            SectionCard(title: "Recent Dictations") {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("Your dictations will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                } else {
                    let recent = Array(items.prefix(3))
                    ForEach(recent) { item in
                        RecentRow(item: item)
                        if item.id != recent.last?.id { Divider().padding(.leading, DS.rowHPadding) }
                    }
                }
            } accessory: {
                if !items.isEmpty {
                    Button {
                        selection = .history
                    } label: {
                        HStack(spacing: 2) {
                            Text("Show All")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
        }
        .onDayChange { dayTick &+= 1 }
    }
}

// MARK: - Header

private struct WelcomeHeader: View {
    @Binding var selection: SidebarPage?
    private var controller = AppController.shared
    private var settings = AppSettings.shared

    init(selection: Binding<SidebarPage?>) { _selection = selection }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        let status = FlussoStatus.current
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(.system(size: 26, weight: .bold))
                Text("Hold \(settings.holdShortcut.displayString) and speak — your words appear wherever you’re typing.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StatusDot(status: status)
                    Text(status.title).fontWeight(.medium)
                    if let detail = status.detail {
                        Text("·").foregroundStyle(.tertiary)
                        Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.callout)
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .padding(.vertical, 4)
                .background(status.color.opacity(0.1), in: .capsule)
                .padding(.top, 2)
                .animation(.snappy, value: status.title)
            }
            Spacer(minLength: 0)
            action
        }
        .padding(20)
        .background {
            ZStack(alignment: .topTrailing) {
                Color.cardFill
                LinearGradient(colors: [Color.indigo.opacity(0.14), Color.purple.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(.rect(cornerRadius: DS.cardRadius + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius + 2, style: .continuous)
                .strokeBorder(Color.cardStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch controller.engineStatus {
        case .noModel:
            Button("Download a Model") { selection = .models }
                .glassProminentButtonStyle()
                .controlSize(.large)
        case .failed:
            Button("Try Again") {
                if let model = ModelCatalog.model(id: settings.selectedModelID) { controller.selectModel(model) }
            }
            .glassButtonStyle()
            .controlSize(.large)
        default:
            EmptyView()
        }
    }
}

// MARK: - Stats

private struct StatCard: View {
    let symbol: String
    let color: Color
    let value: String
    let unit: String?
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(systemName: symbol, color: color, size: 24)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

private struct WeekActivityCard: View {
    let week: [(day: Date, words: Int)]
    let wordsPerMinute: Int?

    private static let weekday = Date.FormatStyle(locale: FlussoFormat.locale).weekday(.narrow)

    var body: some View {
        let maxWords = max(week.map(\.words).max() ?? 0, 1)
        let total = week.reduce(0) { $0 + $1.words }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 Days").font(.headline)
                Spacer()
                Text(total == 1 ? "1 word" : "\(total.formatted(.number.locale(FlussoFormat.locale))) words")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(week.enumerated()), id: \.offset) { index, entry in
                    let isToday = index == week.count - 1
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(entry.words == 0 ? AnyShapeStyle(Color.primary.opacity(0.08))
                                          : isToday ? AnyShapeStyle(Color.accentColor.gradient)
                                          : AnyShapeStyle(Color.accentColor.opacity(0.45).gradient))
                                    .frame(height: entry.words == 0 ? 4
                                           : max(8, geo.size.height * CGFloat(entry.words) / CGFloat(maxWords)))
                            }
                        }
                        .help("\(FlussoFormat.dayTitle(entry.day)): \(entry.words == 1 ? "1 word" : "\(entry.words.formatted(.number.locale(FlussoFormat.locale))) words")")
                        Text(entry.day.formatted(Self.weekday).uppercased())
                            .font(.caption2.weight(isToday ? .bold : .medium))
                            .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 96)
            if let wordsPerMinute {
                Label("You speak about \(wordsPerMinute) words per minute", systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

private struct ShortcutsCard: View {
    let edit: () -> Void
    private var settings = AppSettings.shared

    init(edit: @escaping () -> Void) { self.edit = edit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shortcuts").font(.headline)
                Spacer()
                Button("Edit", action: edit)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            ShortcutLine(symbol: "mic.fill", color: .orange,
                         title: "Dictate", help: "Hold, speak, and release to paste the text",
                         shortcut: settings.holdShortcut)
            Divider()
            ShortcutLine(symbol: "lock.fill", color: .blue,
                         title: "Hands-free", help: "Press once to start, again to stop",
                         shortcut: settings.lockShortcut)
            if !settings.pasteLastShortcut.isEmpty {
                Divider()
                ShortcutLine(symbol: "arrow.uturn.backward", color: .purple,
                             title: "Paste last", help: "Paste your latest transcription again",
                             shortcut: settings.pasteLastShortcut)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

private struct ShortcutLine: View {
    let symbol: String
    let color: Color
    let title: String
    let help: String
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: symbol, color: color, size: 26)
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            LiveShortcutCaps(shortcut: shortcut)
        }
        .frame(minHeight: 34)
        .help(help)
    }
}

// MARK: - Recent

private struct RecentRow: View {
    let item: HistoryItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(item.date, format: FlussoFormat.relative)
                    if let app = item.appName, !app.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        AppBadge(name: app)
                    }
                    if !item.wasPasted {
                        PillBadge(text: "Not pasted", color: .orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextCopyButton(text: item.text)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering || showsHoverControlsAlways ? 1 : 0.0)
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
        .background(hovering ? Color.rowHover : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { HistoryStore.shared.copy(item) }
        }
    }
}
