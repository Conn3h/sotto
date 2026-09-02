import CoreGraphics
import Testing
@testable import Sotto

/// The event tap itself needs Accessibility and real events, so these drive `handle`
/// directly with plain values (the same reduction the C callback performs) and a fake
/// key-state probe, exercising the reconciliation that recovers a release lost while the
/// tap was disabled.
@MainActor
@Suite
struct HotkeyMonitorTests {
    private func pressEvent(_ key: PushToTalkKey) -> (CGEventType, Int64, CGEventFlags) {
        (.flagsChanged, key.keyCode, key.flag)
    }

    @Test func missedReleaseIsReconciledWhenTheTapReenables() {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        var keyDown = false
        monitor.isKeyDown = { _ in keyDown }
        var presses = 0
        var releases = 0
        monitor.onPress = { presses += 1 }
        monitor.onRelease = { releases += 1 }

        // The key goes down through a normal flagsChanged event.
        keyDown = true
        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        #expect(presses == 1)
        #expect(releases == 0)

        // It is released while the tap is disabled: no flagsChanged arrives, only the
        // re-enable. Reconciliation must emit the missed release so the mic does not stay hot.
        keyDown = false
        _ = monitor.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        #expect(releases == 1)
        #expect(presses == 1)

        // A second re-enable with the key already up must not emit a duplicate release.
        _ = monitor.handle(type: .tapDisabledByUserInput, keyCode: 0, flags: [])
        #expect(releases == 1)
    }

    @Test func noSpuriousReleaseWhileTheKeyIsStillHeld() {
        let monitor = HotkeyMonitor()
        monitor.key = .rightOption
        var keyDown = true
        monitor.isKeyDown = { _ in keyDown }
        var releases = 0
        monitor.onPress = {}
        monitor.onRelease = { releases += 1 }

        let down = pressEvent(.rightOption)
        _ = monitor.handle(type: down.0, keyCode: down.1, flags: down.2)
        // The tap flaps but the user is still physically holding: no release.
        _ = monitor.handle(type: .tapDisabledByTimeout, keyCode: 0, flags: [])
        #expect(releases == 0)
    }
}
