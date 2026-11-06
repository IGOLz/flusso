import Observation
import Sparkle
import SwiftUI

/// In-app updates with Sparkle 2 (same setup as ImmichGallery): the feed is
/// the `appcast.xml` attached to the latest GitHub release, every update is
/// EdDSA-signed and must come from the same Developer ID team.
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Debug builds never update themselves (they run from Xcode/DerivedData).
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: AppUpdater.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    private var updater: SPUUpdater { controller.updater }

    private(set) var canCheckForUpdates = false

    /// Checks at launch and once a day.
    var automaticallyChecks = false {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    /// Downloads updates quietly and installs them when Flusso quits.
    var automaticallyDownloads = false {
        didSet {
            if updater.automaticallyDownloadsUpdates != automaticallyDownloads {
                updater.automaticallyDownloadsUpdates = automaticallyDownloads
            }
        }
    }

    var allowsAutomaticDownloads: Bool { updater.allowsAutomaticUpdates }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private init() {
        guard Self.isEnabled else { return }
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        refresh()
    }

    /// Re-reads the preferences (Sparkle's own window can change them too).
    func refresh() {
        guard Self.isEnabled else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }

    /// Shows progress and the result, including "you're up to date".
    func checkForUpdates() {
        guard Self.isEnabled else { return }
        // Flusso is a menu bar app: bring Sparkle's window to the front.
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    /// Called once at launch: a quiet background check (a new version opens
    /// Sparkle's window with the release notes, unless updates install
    /// automatically).
    func checkAtLaunch() {
        guard Self.isEnabled, updater.automaticallyChecksForUpdates else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if !updater.sessionInProgress { updater.checkForUpdatesInBackground() }
        }
    }
}

/// The "Aggiornamenti" section for the settings page.
struct UpdateSettingsSection: View {
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        Section {
            Toggle("Cerca aggiornamenti automaticamente", isOn: $updater.automaticallyChecks)
                .disabled(!AppUpdater.isEnabled)
            if updater.allowsAutomaticDownloads {
                Toggle("Scarica e installa automaticamente", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks || !AppUpdater.isEnabled)
            }
            LabeledContent("Versione", value: updater.versionDescription)
            HStack {
                Spacer()
                Button("Verifica aggiornamenti…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        } header: {
            Text("Aggiornamenti")
        } footer: {
            Text(AppUpdater.isEnabled
                 ? "Flusso cerca una nuova versione all'avvio e una volta al giorno. Gli aggiornamenti automatici vengono installati alla chiusura dell'app."
                 : "Le build di sviluppo non si aggiornano da sole.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { updater.refresh() }
    }
}
