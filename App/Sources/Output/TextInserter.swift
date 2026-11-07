import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// How the text reaches the focused field.
nonisolated enum InsertionMethod: String, Codable, CaseIterable, Sendable {
    /// Clipboard + ⌘V: instant, works almost everywhere.
    case paste
    /// Synthetic key presses, one character at a time: for apps that block
    /// pasting. Slower for long texts.
    case type
}

struct InsertOptions {
    var method: InsertionMethod = .paste
    var restoreClipboard = true
    /// Adds a space after the text, so the next dictation or word can follow.
    var trailingSpace = false
}

enum InsertOutcome: Equatable {
    case pasted
    /// Nothing editable had focus: the caller shows the "not pasted" toast.
    case noFocusedField
}

/// Pastes text into the focused field of the frontmost app (clipboard +
/// synthetic ⌘V, like Handy and Wispr Flow), restoring the clipboard after.
final class TextInserter {
    private enum Focus {
        case editable(AXUIElement)
        case notEditable
        /// The app doesn't expose enough accessibility info: paste anyway.
        case unknown
    }

    private var electronPIDsPrimed = Set<pid_t>()

    /// The user's clipboard saved before our first paste, kept across
    /// back-to-back pastes so it is restored only once, after the last one.
    private var savedClipboard: [NSPasteboardItem]?
    private var ownedChangeCount: Int?
    private var restoreGeneration = 0

    /// Marks the key events Flusso posts, so its own shortcut monitor
    /// ignores them (`eventSourceUserData`).
    nonisolated static let syntheticEventMarker: Int64 = 0x464C_5553 // "FLUS"

    /// The insertion in progress: the next one waits for it, so a long typed
    /// text and a new dictation never interleave.
    private var lastInsertion: Task<InsertOutcome, Never>?

    func insert(_ text: String, options: InsertOptions) async -> InsertOutcome {
        let previous = lastInsertion
        let task = Task {
            _ = await previous?.value
            return await performInsert(text, options: options)
        }
        lastInsertion = task
        return await task.value
    }

    private func performInsert(_ text: String, options: InsertOptions) async -> InsertOutcome {
        let focus = inspectFocus()
        var output = text
        switch focus {
        case .notEditable:
            Log.paste.info("No editable field focused")
            return .noFocusedField
        case .editable(let element):
            output = addLeadingSpaceIfNeeded(text, element: element)
        case .unknown:
            break
        }
        if options.trailingSpace, let last = output.last, !last.isWhitespace {
            output += " "
        }
        switch options.method {
        case .paste: await paste(output, restoreClipboard: options.restoreClipboard)
        case .type: await type(output)
        }
        return .pasted
    }

    // MARK: - Focus inspection

    private func inspectFocus() -> Focus {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .notEditable }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        primeElectronAccessibility(app: app, element: appElement)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focused: AnyObject?
        var error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        if error != .success {
            error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        }

        if error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement
            if isEditable(element) { return .editable(element) }
            if isDefinitelyNotEditable(element) || app.bundleIdentifier == "com.apple.finder" {
                return .notEditable
            }
            return .unknown
        }

        // No focused element. If the app has no focused window either (e.g.
        // the desktop), there is clearly nowhere to paste.
        var window: AnyObject?
        let windowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window)
        if windowError == .noValue || app.bundleIdentifier == "com.apple.finder" {
            return .notEditable
        }
        if error == .noValue, windowError == .success {
            // A window is focused but no element inside: typical for apps
            // with a proper AX tree and nothing selected.
            return isAccessibilityRich(app) ? .notEditable : .unknown
        }
        return .unknown
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        var enabled: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? Bool) == false {
            return false
        }
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        if subrole == "AXSecureTextField" { return true }
        // Web content: contenteditable regions expose an editable ancestor.
        var ancestor: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &ancestor) == .success, ancestor != nil {
            return true
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if role != "AXWebArea",
           AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue,
           !["AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXIncrementor", "AXColorWell"].contains(role) {
            return true
        }
        return false
    }

    private func isDefinitelyNotEditable(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        var enabled: AnyObject?
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role),
           AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? Bool) == false {
            return true
        }
        return [
            "AXWebArea", "AXButton", "AXLink", "AXImage", "AXStaticText", "AXList", "AXOutline",
            "AXTable", "AXRow", "AXCell", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXSlider", "AXTabGroup", "AXToolbar", "AXDisclosureTriangle", "AXBrowser",
        ].contains(role)
    }

    /// Native AppKit/Catalyst apps always expose their focused element; for
    /// them "no focused element" really means nothing is focused.
    private func isAccessibilityRich(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return bundleID.hasPrefix("com.apple.")
    }

    /// Electron apps only build their accessibility tree when asked to.
    private func primeElectronAccessibility(app: NSRunningApplication, element: AXUIElement) {
        let pid = app.processIdentifier
        guard !electronPIDsPrimed.contains(pid) else { return }
        electronPIDsPrimed.insert(pid)
        if let bundleURL = app.bundleURL,
           FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Adds a space when dictating right after a word, like Wispr Flow.
    private func addLeadingSpaceIfNeeded(_ text: String, element: AXUIElement) -> String {
        guard let first = text.first, first.isLetter || first.isNumber else { return text }
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return text }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location > 0 else { return text }
        var previousRange = CFRange(location: range.location - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &previousRange) else { return text }
        var previous: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, param, &previous) == .success,
              let char = (previous as? String)?.last else { return text }
        if char.isWhitespace || char.isNewline || "([{\"'«“‘/-".contains(char) { return text }
        return " " + text
    }

    // MARK: - Paste

    private func paste(_ text: String, restoreClipboard: Bool) async {
        let pasteboard = NSPasteboard.general
        if restoreClipboard {
            // If the clipboard still holds our previous paste, the user's
            // original is already saved: keep it.
            if !(savedClipboard != nil && ownedChangeCount == pasteboard.changeCount) {
                savedClipboard = snapshot(pasteboard)
            }
        } else {
            savedClipboard = nil
        }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Ask clipboard managers to ignore this transient entry.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount
        ownedChangeCount = ourChangeCount

        postCommandV()

        guard restoreClipboard else { return }
        restoreGeneration += 1
        let generation = restoreGeneration
        try? await Task.sleep(for: .milliseconds(600))
        // A later paste took over the restore.
        guard generation == restoreGeneration, let saved = savedClipboard else { return }
        savedClipboard = nil
        ownedChangeCount = nil
        // Only restore if nobody else wrote to the clipboard meanwhile.
        guard pasteboard.changeCount == ourChangeCount else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // MARK: - Typing

    /// Types the text as synthetic key presses carrying Unicode strings, so
    /// it works whatever the keyboard layout. Line breaks are sent as Return.
    private func type(_ text: String) async {
        let source = CGEventSource(stateID: .privateState)
        for (index, character) in text.enumerated() {
            if character.isNewline {
                postKey(CGKeyCode(kVK_Return), source: source)
            } else {
                let units = Array(String(character).utf16)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                for event in [down, up] {
                    // Never combine with modifiers the user may still hold.
                    event?.flags = []
                    event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event?.post(tap: .cghidEventTap)
                }
            }
            // Apps drop characters that arrive too fast; yield regularly.
            if index % 4 == 3 { try? await Task.sleep(for: .milliseconds(4)) }
        }
    }

    private func postKey(_ key: CGKeyCode, source: CGEventSource?) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
