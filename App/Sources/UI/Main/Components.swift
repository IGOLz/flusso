import AppKit
import SwiftUI

// MARK: - Key caps

/// A single keyboard key, drawn like a physical key cap.
struct KeyCap: View {
    let label: String
    /// Lit while the physical key is held.
    var isPressed = false
    @Environment(\.controlSize) private var controlSize

    private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

    var body: some View {
        Text(label)
            .font(.system(isLarge ? .title3 : .callout, design: .rounded).weight(.medium))
            .foregroundStyle(isPressed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, isLarge ? 11 : 7)
            .frame(minWidth: isLarge ? 36 : 26, minHeight: isLarge ? 34 : 24)
            .background {
                RoundedRectangle(cornerRadius: isLarge ? 8 : 6, style: .continuous)
                    .fill(isPressed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background))
                    .shadow(color: isPressed ? Color.accentColor.opacity(0.55) : .black.opacity(0.22),
                            radius: isPressed ? 6 : 0, x: 0, y: isPressed ? 0 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: isLarge ? 8 : 6, style: .continuous)
                    .strokeBorder(isPressed ? AnyShapeStyle(Color.white.opacity(0.35)) : AnyShapeStyle(.separator),
                                  lineWidth: 1)
            }
            // Pressed keys sink slightly, like a real key.
            .offset(y: isPressed ? 1 : 0)
            .animation(.snappy(duration: 0.12), value: isPressed)
    }
}

/// Key caps of a shortcut that light up live as the user presses the keys
/// (anywhere, no click needed). `onFullMatch` reports when the whole
/// combination is held.
struct LiveShortcutCaps: View {
    let shortcut: Shortcut
    var onFullMatch: (Bool) -> Void = { _ in }

    @State private var keyboard = KeyboardSnapshot()
    @State private var poller: Timer?

    var body: some View {
        let parts = shortcut.capParts
        HStack(spacing: 4) {
            if parts.isEmpty {
                Text("Nessuna").foregroundStyle(.secondary)
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                KeyCap(label: part.label, isPressed: part.isPressed(keyboard))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.keyCaps.joined(separator: " + "))
        .onAppear {
            keyboard = AppController.shared.keyboardSnapshot
            onFullMatch(shortcut.isFullyPressed(keyboard))
            startPolling()
        }
        .onDisappear(perform: stopPolling)
        .onChange(of: keyboard) { _, new in onFullMatch(shortcut.isFullyPressed(new)) }
        .onChange(of: shortcut) { _, new in onFullMatch(new.isFullyPressed(keyboard)) }
    }

    private func startPolling() {
        guard poller == nil else { return }
        // Reading a mutex-guarded snapshot at display rate is cheap.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = AppController.shared.keyboardSnapshot
                if now != keyboard { keyboard = now }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func stopPolling() {
        poller?.invalidate()
        poller = nil
    }
}

/// A row of key caps, e.g. `fn` `Spazio`.
struct KeyCaps: View {
    let caps: [String]

    init(_ caps: [String]) { self.caps = caps }
    init(_ shortcut: Shortcut) { self.caps = shortcut.keyCaps }

    var body: some View {
        HStack(spacing: 4) {
            if caps.isEmpty {
                Text("Nessuna").foregroundStyle(.secondary)
            }
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                KeyCap(label: cap)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.joined(separator: " + "))
    }
}

// MARK: - Small building blocks

/// A System Settings–style coloured icon tile.
struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .background(color.gradient, in: shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 0.5)
            }
    }
}

/// A small coloured capsule label ("Consigliato", "Non incollato"…).
struct PillBadge: View {
    let text: String
    var color: Color = .accentColor
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: .capsule)
    }
}

/// "Concesso" check shown next to a granted permission.
struct GrantedLabel: View {
    var body: some View {
        Label("Concesso", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.callout.weight(.medium))
    }
}

/// A plain rounded card used outside of `Form`s.
extension View {
    func card(highlighted: Bool = false) -> some View {
        cardSurface(radius: 16, highlighted: highlighted)
    }
}

// MARK: - Shared rows

/// Tip about the 🌐/fn key, which macOS uses for the emoji picker / dictation by default.
struct FnKeyTip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text("Usare fn in modo affidabile")
                    .font(.headline)
                Text("In Impostazioni di Sistema › Tastiera imposta «Premi il tasto 🌐 per» su «Non fare nulla», così macOS non apre emoji o Dettatura quando usi fn.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Apri impostazioni Tastiera…") {
                    Permissions.shared.openKeyboardSettings()
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Copy-to-clipboard button with a short checkmark confirmation.
struct TextCopyButton: View {
    let text: String
    var title: String?
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            if let title {
                Label(copied ? "Copiato" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18)
            }
        }
        .help("Copia")
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// MARK: - Window title

/// `MainView` lives in an `NSHostingController` that doesn't bridge
/// `.navigationTitle` to the window, so set the NSWindow title directly.
struct WindowTitle: NSViewRepresentable {
    let title: String
    var subtitle: String = ""

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
        view.subtitle = subtitle
        view.apply()
    }

    final class TitleView: NSView {
        var title = ""
        var subtitle = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // MainWindowController assigns its own title right after creating
            // the window: re-apply once that has happened.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window else { return }
            if window.title != title { window.title = title }
            if window.subtitle != subtitle { window.subtitle = subtitle }
        }
    }
}
