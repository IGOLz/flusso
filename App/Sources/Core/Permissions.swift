import AppKit
import AVFoundation
import ApplicationServices
import Observation

enum MicrophonePermission: Equatable {
    case notDetermined, granted, denied
}

/// Microphone + Accessibility (needed for the global shortcut event tap and
/// for pasting into the focused app).
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var microphone: MicrophonePermission = .notDetermined
    private(set) var accessibility = false

    var allGranted: Bool { microphone == .granted && accessibility }

    @ObservationIgnored private var pollTimer: Timer?

    private init() {
        refresh()
        // Accessibility has no change notification: poll while it is missing.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let mic: MicrophonePermission = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        if mic != microphone { microphone = mic }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Shows the system prompt (and adds Flusso to the Accessibility list).
    func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
