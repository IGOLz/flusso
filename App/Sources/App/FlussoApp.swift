import AppKit
import SwiftUI

@main
struct FlussoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // ggml's Metal backend aborts at exit while a model is still loaded.
        LocalFormatter.shared.unloadNow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SelfTest.runIfRequested() { return }
        #endif
        // Creates the overlay panel up front so the first dictation shows instantly.
        OverlayController.runDemoIfRequested()
        #if DEBUG
        // UI-only instance (screenshots, design work): no global shortcuts,
        // no microphone, so it can't interfere with the installed Flusso.
        if ProcessInfo.processInfo.environment["FLUSSO_UI_ONLY"] == "1" {
            if DebugSample.isEnabled { AppController.shared.showSampleReadyState() }
            MainWindowController.shared.show()
            return
        }
        #endif
        AppController.shared.start()
        AppUpdater.shared.checkAtLaunch()
        if !AppSettings.shared.hasCompletedOnboarding {
            MainWindowController.shared.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The menu bar icon reflects the dictation phase.
private struct MenuBarIcon: View {
    private var controller = AppController.shared

    var body: some View {
        switch controller.phase {
        case .idle: Image(systemName: "waveform")
        case .recording: Image(systemName: "waveform.badge.mic")
        case .transcribing: Image(systemName: "ellipsis")
        }
    }
}

private struct MenuBarMenu: View {
    private var controller = AppController.shared
    private var settings = AppSettings.shared

    var body: some View {
        Text(statusText)
        Divider()
        Button("Open Flusso…") { MainWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            .disabled(!AppUpdater.shared.canCheckForUpdates)
        Divider()
        Text("Hold \(settings.holdShortcut.displayString) to dictate")
        Text("\(settings.lockShortcut.displayString) for hands-free mode")
        Divider()
        Button("Paste Last Transcription") { controller.pasteLastTranscription(fromMenu: true) }
            .disabled(HistoryStore.shared.items.isEmpty || controller.phase != .idle)
        Divider()
        Button("Quit Flusso") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch controller.engineStatus {
        case .noModel: "No model installed"
        case .loading: "Loading model…"
        case .ready: "Ready"
        case .failed(let message): "Error: \(message)"
        }
    }
}

/// Hosts `MainView` in a regular window. Flusso is a menu bar app: it shows in
/// the Dock only while this window is open.
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView())
            hosting.sceneBridgingOptions = [.title, .toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Flusso"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 860, height: 600))
            window.minSize = NSSize(width: 720, height: 500)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("FlussoMainWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        AppController.shared.shortcutPreview = false
        NSApp.setActivationPolicy(.accessory)
    }
}
