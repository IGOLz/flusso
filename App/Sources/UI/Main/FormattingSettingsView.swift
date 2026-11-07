import AppKit
import SwiftUI

/// How dictated text is formatted before it's inserted.
struct FormattingSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var availability = SmartFormatter.availability
    @State private var sample = ""
    @State private var result: String?
    @State private var formatting = false

    var body: some View {
        PageScroll {
            PageHero(symbol: "wand.and.stars", color: .purple,
                     title: "Formatting",
                     description: "Flusso tidies up what you say before inserting it — on your Mac, without sending anything anywhere.")

            smartFormatting
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            availability = SmartFormatter.availability
        }
    }

    // MARK: Smart formatting

    @ViewBuilder
    private var smartFormatting: some View {
        SectionCard(title: "Smart Formatting",
                    footer: "Uses Apple Intelligence’s on-device model, only when you correct yourself or number a list, so most dictations aren’t slowed down. If its edit changes your words, Flusso keeps the original.") {
            ToggleRow(symbol: "arrow.uturn.backward", color: .purple,
                      title: "Fix self-corrections and lists",
                      subtitle: "“At 5, no wait, at 6” becomes “At 6”. “First milk, second bread” becomes a numbered list.",
                      isOn: $settings.smartFormatting)
                .disabled(availability != .available)
            if settings.smartFormatting && availability == .available {
                RowDivider()
                tester
            }
        }

        if let message = unavailableMessage {
            NoticeCard(symbol: "exclamationmark.triangle.fill", color: .orange,
                       title: "Apple Intelligence not available",
                       message: message) {
                if availability == .appleIntelligenceOff {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .glassButtonStyle()
                }
            }
        }
    }

    private var unavailableMessage: String? {
        switch availability {
        case .available: nil
        case .unsupportedOS: "Smart formatting needs macOS 26 or later."
        case .deviceNotEligible: "This Mac doesn’t support Apple Intelligence."
        case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings to use smart formatting."
        case .modelNotReady: "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable: "Apple Intelligence isn’t available right now."
        }
    }

    private var tester: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField("Try it", text: $sample,
                          prompt: Text("Try it: Call me at 5, no wait, at 6."))
                    .textFieldStyle(.plain)
                    .onSubmit(run)
                    .disabled(formatting)
                    .onChange(of: sample) { result = nil }
                Button("Format", action: run)
                    .glassButtonStyle()
                    .disabled(sample.trimmingCharacters(in: .whitespaces).isEmpty || formatting)
            }
            if formatting {
                ProgressView().controlSize(.small).padding(.leading, 28)
            } else if let result {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: result == sample ? "equal.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(result == sample ? Color.secondary : Color.green)
                        .frame(width: 18)
                    Text(result == sample ? "No changes needed." : result)
                        .fontWeight(.medium)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, DS.rowHPadding)
        .padding(.vertical, 12)
        .animation(.snappy, value: result)
    }

    private func run() {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !formatting else { return }
        formatting = true
        let input = sample
        Task {
            let output = await SmartFormatter.format(text)
            formatting = false
            guard sample == input else { return }
            result = output == text ? input : output
        }
    }
}
