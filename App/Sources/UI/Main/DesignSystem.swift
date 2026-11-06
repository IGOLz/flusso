import AppKit
import SwiftUI

// MARK: - Tokens

/// Shared spacing, radii and sizes, so every page has the same rhythm.
nonisolated enum DS {
    static let pagePadding: CGFloat = 24
    static let pageTop: CGFloat = 18
    static let sectionSpacing: CGFloat = 24
    static let headerSpacing: CGFloat = 8
    static let cardRadius: CGFloat = 14
    static let rowHPadding: CGFloat = 14
    static let rowVPadding: CGFloat = 11
    static let rowIcon: CGFloat = 26
    static let gridSpacing: CGFloat = 12
    static let maxContentWidth: CGFloat = 780
}

extension Color {
    /// Page background behind the cards: a soft grey in light mode, the window
    /// colour in dark mode.
    static let pageBackground = Color(nsColor: .flussoDynamic(
        light: NSColor(calibratedWhite: 0.962, alpha: 1),
        dark: .windowBackgroundColor))

    /// Card surface: white in light mode, a lifted translucent grey in dark mode.
    static let cardFill = Color(nsColor: .flussoDynamic(
        light: .white,
        dark: NSColor(calibratedWhite: 1, alpha: 0.055)))

    static let cardStroke = Color(nsColor: .flussoDynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.075),
        dark: NSColor(calibratedWhite: 1, alpha: 0.075)))

    /// Hover/pressed tint inside cards.
    static let rowHover = Color(nsColor: .flussoDynamic(
        light: NSColor(calibratedWhite: 0, alpha: 0.035),
        dark: NSColor(calibratedWhite: 1, alpha: 0.045)))
}

extension NSColor {
    nonisolated static func flussoDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Surfaces

struct CardSurface: ViewModifier {
    var radius: CGFloat = DS.cardRadius
    var highlighted = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape
                    .fill(Color.cardFill)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.045), radius: 2, y: 1)
            }
            .overlay {
                shape.strokeBorder(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.cardStroke),
                                   lineWidth: highlighted ? 1.5 : 1)
            }
            .clipShape(shape)
    }
}

extension View {
    func cardSurface(radius: CGFloat = DS.cardRadius, highlighted: Bool = false) -> some View {
        modifier(CardSurface(radius: radius, highlighted: highlighted))
    }

    /// Background of every sidebar page.
    func pageBackground() -> some View {
        background(Color.pageBackground.ignoresSafeArea())
    }
}

// MARK: - Page scaffolding

/// Scrollable, centred column used by every page.
struct PageScroll<Content: View>: View {
    var spacing: CGFloat = DS.sectionSpacing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, DS.pagePadding)
                .padding(.top, DS.pageTop)
                .padding(.bottom, 32)
                .frame(maxWidth: DS.maxContentWidth)
                .frame(maxWidth: .infinity)
                .background(OverlayScrollers())
        }
        .pageBackground()
    }
}

/// Uses overlay scrollers for the enclosing scroll view, so a legacy
/// (always visible) scroll bar doesn't take 15 pt from the content: every
/// page keeps the same width whether it scrolls or not.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerStyleView { ScrollerStyleView() }
    func updateNSView(_ view: ScrollerStyleView, context: Context) { view.apply() }

    final class ScrollerStyleView: NSView {
        private var observing = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            guard !observing else { return }
            observing = true
            // AppKit resets the style when the user preference changes.
            NotificationCenter.default.addObserver(self, selector: #selector(preferenceChanged),
                                                   name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                   object: nil)
        }

        @objc private func preferenceChanged() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }
    }
}

/// Large icon + title + description at the top of a page (System Settings style).
struct PageHero<Accessory: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let description: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(systemName: symbol, color: color, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

extension PageHero where Accessory == EmptyView {
    init(symbol: String, color: Color, title: String, description: String) {
        self.init(symbol: symbol, color: color, title: title, description: description) { EmptyView() }
    }
}

/// Section title (+ optional trailing accessory), a card with the rows, and an
/// optional footer.
struct SectionCard<Content: View, Accessory: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: DS.headerSpacing) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title { SectionTitle(title) }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .cardSurface()
            if let footer {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension SectionCard where Accessory == EmptyView {
    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, content: content) { EmptyView() }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.leading, 4)
    }
}

/// A settings row: coloured icon, title, optional subtitle and a trailing control.
struct SettingRow<Trailing: View>: View {
    var symbol: String?
    var color: Color = .gray
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                IconTile(systemName: symbol, color: color, size: DS.rowIcon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, DS.rowVPadding)
        .frame(minHeight: 46)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(symbol: String? = nil, color: Color = .gray, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A toggle row with a switch on the trailing edge.
struct ToggleRow: View {
    var symbol: String?
    var color: Color = .gray
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, color: color, title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// Hairline between rows of a card, inset past the row icon.
struct RowDivider: View {
    var inset: CGFloat = DS.rowHPadding + DS.rowIcon + 12

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// Tinted call-out card (missing permissions, tips).
struct NoticeCard<Action: View>: View {
    let symbol: String
    var color: Color = .orange
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(14)
        .background(color.opacity(0.09), in: .rect(cornerRadius: DS.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(color.opacity(0.25), lineWidth: 1)
        }
    }
}

/// Friendly placeholder inside a page (no data yet / no results).
struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 2)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(Color.cardStroke, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }
}

/// Small round icon button that appears on hover (copy, delete…).
struct HoverIconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(role == .destructive && hovering ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .background(hovering ? Color.rowHover : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Layouts

/// Equal-width columns that collapse to fewer columns when space runs out.
/// Items in the same row share the tallest item's height.
struct AdaptiveColumns: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat = DS.gridSpacing

    private func columns(for width: CGFloat, count: Int) -> Int {
        var columns = max(count, 1)
        while columns > 1, CGFloat(columns) * minColumnWidth + CGFloat(columns - 1) * spacing > width {
            columns -= 1
        }
        return columns
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (columnWidth: CGFloat, columns: Int, heights: [CGFloat]) {
        let columns = columns(for: width, count: subviews.count)
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0)
        }
        return (columnWidth, columns, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minColumnWidth * CGFloat(subviews.count) + spacing * CGFloat(max(subviews.count - 1, 0)))
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + spacing * CGFloat(max(layout.heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (rowIndex, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = rowIndex * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: layout.columnWidth, height: height))
            }
            y += height + spacing
        }
    }
}

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            if x > 0, x + width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            widest = max(widest, x + width)
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, bounds.width)
            if x > bounds.minX, x + width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: size.height))
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Flusso status

/// What Flusso is doing right now, shared by the sidebar and the dashboard.
struct FlussoStatus {
    enum Kind { case recording, busy, ready, warning, error }

    let kind: Kind
    let title: String
    var detail: String?

    var color: Color {
        switch kind {
        case .recording, .error: .red
        case .busy: .blue
        case .ready: .green
        case .warning: .orange
        }
    }

    static var current: FlussoStatus {
        let controller = AppController.shared
        let permissions = Permissions.shared
        let model = ModelCatalog.model(id: AppSettings.shared.selectedModelID)
        switch (controller.phase, controller.engineStatus) {
        case (.recording, _):
            return FlussoStatus(kind: .recording, title: "In ascolto…")
        case (.transcribing, _):
            return FlussoStatus(kind: .busy, title: "Trascrizione in corso…")
        case (_, .loading):
            return FlussoStatus(kind: .busy, title: "Caricamento di \(model?.name ?? "modello")…")
        case (_, .noModel):
            return FlussoStatus(kind: .warning, title: "Nessun modello installato")
        case (_, .failed(let message)):
            return FlussoStatus(kind: .error, title: "Errore del modello", detail: message)
        case (_, .ready):
            if permissions.allGranted {
                return FlussoStatus(kind: .ready, title: "Pronto", detail: model?.name)
            }
            return FlussoStatus(kind: .warning, title: "Permessi mancanti", detail: model?.name)
        }
    }
}

/// Coloured dot (pulsing while recording) or a spinner while busy.
struct StatusDot: View {
    let status: FlussoStatus

    var body: some View {
        Group {
            if status.kind == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(status.color.gradient)
                    .frame(width: 8, height: 8)
                    .background {
                        Circle().fill(status.color.opacity(0.25)).frame(width: 14, height: 14)
                    }
                    .phaseAnimator([false, true], trigger: status.kind == .recording) { dot, phase in
                        dot.opacity(status.kind == .recording && phase ? 0.4 : 1)
                    }
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - App icons

/// Icons of the apps transcriptions were pasted into, looked up by name.
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(for appName: String) -> NSImage? {
        if let cached = cache[appName] { return cached }
        if misses.contains(appName) { return nil }
        var image = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == appName }?.icon
        if image == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                           "/Applications/Utilities", "\(home)/Applications"]
            for folder in folders {
                let path = "\(folder)/\(appName).app"
                if FileManager.default.fileExists(atPath: path) {
                    image = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        if let image { cache[appName] = image } else { misses.insert(appName) }
        return image
    }
}

/// App icon + name, used in transcription metadata.
struct AppBadge: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            if let icon = AppIconCache.icon(for: name) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "app.dashed")
            }
            Text(name).lineLimit(1)
        }
    }
}

// MARK: - Formatting

enum FlussoFormat {
    static let italian = Locale(identifier: "it_IT")

    /// "Oggi", "Ieri", "Lunedì 3 novembre" (with the year if not this one).
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Oggi" }
        if calendar.isDateInYesterday(day) { return "Ieri" }
        var style = Date.FormatStyle(locale: italian).weekday(.wide).day().month(.wide)
        if !calendar.isDate(day, equalTo: .now, toGranularity: .year) { style = style.year() }
        let text = day.formatted(style)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: italian).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "12 s", "1 min 5 s".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1)) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// Value + unit for big numbers: ("12", "min"), ("1,5", "h").
    static func savedTime(_ seconds: Double) -> (value: String, unit: String) {
        if seconds < 60 { return ("\(Int(seconds.rounded()))", "s") }
        let minutes = seconds / 60
        if minutes < 60 { return ("\(Int(minutes.rounded()))", "min") }
        let hours = minutes / 60
        return (hours.formatted(.number.precision(.fractionLength(0...1)).locale(italian)), "h")
    }
}

// MARK: - Stats

/// Numbers for the dashboard, computed from the saved history.
struct DictationStats {
    /// Typing speed used to estimate the time saved by dictating.
    static let typingWPM = 40.0

    let words: Int
    let transcriptions: Int
    let savedSeconds: Double
    let wordsPerMinute: Int?
    let streak: Int
    let dictatedToday: Bool
    /// Last 7 days, oldest first.
    let week: [(day: Date, words: Int)]

    init(items: [HistoryItem], now: Date = .now, calendar: Calendar = .current) {
        var words = 0
        var spoken = 0.0
        var perDay: [Date: Int] = [:]
        for item in items {
            let count = item.text.split(whereSeparator: \.isWhitespace).count
            words += count
            spoken += item.duration
            perDay[calendar.startOfDay(for: item.date), default: 0] += count
        }
        self.words = words
        transcriptions = items.count
        savedSeconds = max(0, Double(words) / Self.typingWPM * 60 - spoken)
        wordsPerMinute = spoken > 5 ? Int((Double(words) / (spoken / 60)).rounded()) : nil

        let today = calendar.startOfDay(for: now)
        dictatedToday = perDay[today] != nil
        var streak = 0
        var day = dictatedToday ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while perDay[day] != nil {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        self.streak = streak
        week = (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return (day, perDay[day] ?? 0)
        }
    }
}

// MARK: - Day changes

extension View {
    /// Calls `action` when the calendar day or time zone changes, or the app
    /// becomes active (e.g. after the Mac woke up the next morning).
    func onDayChange(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in action() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in action() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in action() }
    }
}

/// Hover-only controls stay visible when Full Keyboard Access is on, so
/// keyboard users can see what they focus.
@MainActor
var showsHoverControlsAlways: Bool { NSApplication.shared.isFullKeyboardAccessEnabled }

// MARK: - Debug sample data

#if DEBUG
/// `FLUSSO_DEBUG_SAMPLE=1`: pages show sample history and dictionary words
/// (in memory only, nothing is saved) so screenshots don't need real data.
enum DebugSample {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["FLUSSO_DEBUG_SAMPLE"] == "1" }

    static let history: [HistoryItem] = {
        let now = Date.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            HistoryItem(text: "Ricordami di mandare a Giulia la bozza della presentazione entro venerdì, con i nuovi grafici sulle vendite.", date: ago(3), wasPasted: true, appName: "Notes", duration: 7),
            HistoryItem(text: "Perfetto, ci vediamo domani alle 10 in ufficio.", date: ago(18), wasPasted: true, appName: "Messages", duration: 3),
            HistoryItem(text: "Il problema nasce dal fatto che la toolbar viene creata solo nelle pagine con elementi: aggiungiamo una toolbar fissa alla finestra.", date: ago(52), wasPasted: true, appName: "Xcode", duration: 9),
            HistoryItem(text: "Grazie mille per il feedback, lo integro nella prossima versione.", date: ago(60 * 26), wasPasted: true, appName: "Mail", duration: 4),
            HistoryItem(text: "Lista della spesa: latte, pane, pomodori, basilico e parmigiano.", date: ago(60 * 29), wasPasted: false, appName: nil, duration: 5),
            HistoryItem(text: "Domani riunione con il team di design per rivedere la nuova dashboard di Flusso.", date: ago(60 * 50), wasPasted: true, appName: "Calendar", duration: 6),
            HistoryItem(text: "Ok, procedi pure con il merge.", date: ago(60 * 74), wasPasted: true, appName: "Slack", duration: 2),
        ]
    }()

    static let dictionary: [DictionaryEntry] = [
        DictionaryEntry(term: "Flusso"),
        DictionaryEntry(term: "SwiftUI", spokenAs: "suift ui"),
        DictionaryEntry(term: "Craciun"),
        DictionaryEntry(term: "Parakeet"),
        DictionaryEntry(term: "Liquid Glass"),
        DictionaryEntry(term: "macOS", spokenAs: "mac o esse"),
        DictionaryEntry(term: "GitHub"),
        DictionaryEntry(term: "Xcode"),
    ]
}
#endif

/// History items shown by the UI (sample data in DEBUG screenshots).
extension HistoryStore {
    /// Destructive actions are disabled while sample data is shown, so they
    /// can never touch the real history.
    var isShowingSamples: Bool {
        #if DEBUG
        return DebugSample.isEnabled
        #else
        return false
        #endif
    }

    var displayedItems: [HistoryItem] {
        #if DEBUG
        if DebugSample.isEnabled { return DebugSample.history }
        #endif
        return items
    }
}
