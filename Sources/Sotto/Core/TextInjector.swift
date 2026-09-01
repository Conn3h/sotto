import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Puts text into whatever has keyboard focus. Two strategies, in order: an Accessibility
/// write that is trusted only when the caret verifiably moved, then the pasteboard plus a
/// synthesized Command-V with the previous pasteboard contents restored afterwards.
@MainActor
enum TextInjector {
    private typealias SavedItem = [NSPasteboard.PasteboardType: Data]

    /// Virtual key code of V on an ANSI keyboard (kVK_ANSI_V).
    private static let vKeyCode: CGKeyCode = 9
    /// Long enough for the target to observe the new pasteboard generation before ⌘V.
    private static let pasteboardSettleDelay: Duration = .milliseconds(40)
    /// The paste is asynchronous in the target; restoring earlier would hand it our old
    /// contents instead of the text.
    private static let pasteCompletionDelay: Duration = .milliseconds(500)

    /// Returns once the text has been handed to the focused app. On the paste path the
    /// pasteboard is restored in the background `pasteCompletionDelay` later, so the
    /// caller (and the user) does not wait on it.
    static func insert(_ text: String) async {
        guard !text.isEmpty else {
            Log.inject.info("nothing to insert")
            return
        }
        if let reason = insertViaAccessibility(text) {
            Log.inject.info(
                "accessibility path not trusted (\(reason, privacy: .public)); pasting \(text.count, privacy: .public) chars"
            )
            await insertViaPasteboard(text)
        }
    }

    // MARK: Accessibility

    /// Nil when the write was verified by caret movement; otherwise the reason to fall back.
    /// "Moved" rather than "moved by exactly the text length": autocorrect and newline
    /// normalisation shift the caret by other amounts, and falling back after a write that
    /// did land would paste the text twice.
    private static func insertViaAccessibility(_ text: String) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusedError == .success, let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return "no focused element (AXError \(focusedError.rawValue))"
        }
        let focused = focusedValue as! AXUIElement

        var settable: DarwinBoolean = false
        let settableError = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
        guard settableError == .success else {
            return "selected text settability unknown (AXError \(settableError.rawValue))"
        }
        guard settable.boolValue else {
            return "selected text is not settable"
        }

        guard let before = selectedRange(of: focused) else {
            return "selection range unreadable before the write"
        }
        let writeError = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString)
        guard writeError == .success else {
            return "write failed (AXError \(writeError.rawValue))"
        }
        guard let after = selectedRange(of: focused) else {
            return "selection range unreadable after the write"
        }
        guard after.location != before.location || after.length != before.length else {
            return "write reported success but the selection did not move"
        }
        Log.inject.info(
            "inserted \(text.count, privacy: .public) chars via accessibility; selection \(before.location, privacy: .public)+\(before.length, privacy: .public) -> \(after.location, privacy: .public)+\(after.length, privacy: .public)"
        )
        return nil
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            Log.inject.debug("selected text range unavailable (AXError \(error.rawValue, privacy: .public))")
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            Log.inject.debug("selected text range has unexpected value type \(AXValueGetType(axValue).rawValue, privacy: .public)")
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            Log.inject.debug("selected text range could not be unpacked")
            return nil
        }
        return range
    }

    // MARK: Pasteboard

    private static func insertViaPasteboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            Log.inject.error("pasteboard write failed; nothing inserted")
            restore(saved, to: pasteboard)
            return
        }
        let ourChangeCount = pasteboard.changeCount

        await wait(pasteboardSettleDelay)
        guard postCommandV() else {
            Log.inject.error("could not synthesize Command-V; nothing inserted")
            restoreIfUnchanged(saved, since: ourChangeCount)
            return
        }
        Log.inject.info("pasted \(text.count, privacy: .public) chars via Command-V")

        Task { @MainActor in
            await wait(pasteCompletionDelay)
            restoreIfUnchanged(saved, since: ourChangeCount)
        }
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let pairs = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else {
                    Log.inject.debug("pasteboard type \(type.rawValue, privacy: .public) had no data to save")
                    return nil
                }
                return (type, data)
            }
            return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Restores the saved items only if nobody else has written to the pasteboard since
    /// our write; otherwise the user's newer copy wins and the skip is logged.
    private static func restoreIfUnchanged(_ saved: [SavedItem], since changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else {
            Log.inject.info(
                "pasteboard restore skipped: it changed underneath us (changeCount \(changeCount, privacy: .public) -> \(pasteboard.changeCount, privacy: .public))"
            )
            return
        }
        restore(saved, to: pasteboard)
    }

    private static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                if !item.setData(data, forType: type) {
                    Log.inject.error("pasteboard restore could not set type \(type.rawValue, privacy: .public)")
                }
            }
            return item
        }
        guard !items.isEmpty else {
            Log.inject.info("pasteboard restored: it was empty")
            return
        }
        guard pasteboard.writeObjects(items) else {
            Log.inject.error("pasteboard restore failed to write \(items.count, privacy: .public) items")
            return
        }
        Log.inject.info("pasteboard restored: \(items.count, privacy: .public) items")
    }

    /// Command-V from a private event source with the flags set explicitly, so live hardware
    /// modifier state (a finger still resting on a key) is never inherited.
    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.inject.error("could not create a private event source")
            return false
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            Log.inject.error("could not create Command-V key events")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func wait(_ duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            Log.inject.debug("injection wait cancelled")
        }
    }
}
