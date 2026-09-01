import AppKit
import SwiftUI

/// The single source of every visual constant in Sotto: the "quiet instrument" design
/// direction from spec §6.14 as Swift values. Views must never contain a literal colour,
/// size, radius, font or duration — every such value is a token here. If a component needs
/// a value that has no token yet, add one to the appropriate namespace below; never rename
/// or remove a token another batch may already depend on.
///
/// Two rules are encoded by these tokens but not enforced by the compiler, so state them
/// where every consumer will read them:
///
/// 1. **`Color.accent` means "recording", and nothing else.** It is a muted coral red used
///    for the recording lamp, the mic-active affordance, and the HUD's error text. It must
///    never be used for a button, a link, a selection highlight, or any other kind of
///    emphasis.
/// 2. **`Color.meterLow` and `Color.meterHigh` are level-meter colours only.** The
///    restrained green-to-amber scale they form appears nowhere else in the chrome; using
///    either colour outside a level meter would make the meter's own coding ambiguous.
///
/// No gradients anywhere: every colour token below is a flat fill. Depth comes from
/// `Color.panel` / `Color.panelRaised` fills and `Color.hairline` borders, not shading.
enum DS {}

// MARK: - Color

extension DS {
    /// Flat, appearance-adaptive fills and ink colours. Light appearance is warm off-white
    /// panels on a slightly darker warm ground with near-black ink; dark appearance is
    /// near-black panels on true black with off-white ink. Every colour resolves per the
    /// current `NSAppearance`, so a single value works in both.
    enum Color {
        /// The window/screen backdrop behind every panel.
        static let ground = adaptiveColor("DS.ground", light: 0xE9E5DD, dark: 0x000000)
        /// The standard surface fill for cards, rows and controls.
        static let panel = adaptiveColor("DS.panel", light: 0xF6F3EC, dark: 0x151412)
        /// A slightly lighter surface for content that should read as sitting above
        /// `panel`, e.g. a hovered row or an inline field.
        static let panelRaised = adaptiveColor("DS.panelRaised", light: 0xFCFAF4, dark: 0x1E1C19)

        /// Primary text and iconography.
        static let ink = adaptiveColor("DS.ink", light: 0x1C1B18, dark: 0xEDEAE3)
        /// Secondary text: captions under a headline, metadata in a list row.
        static let inkSecondary = adaptiveColor("DS.inkSecondary", light: 0x5C594E, dark: 0xB0AB9F)
        /// Tertiary text and disabled iconography: the least emphasis before invisible.
        static let inkTertiary = adaptiveColor("DS.inkTertiary", light: 0x8B8778, dark: 0x7D7A70)

        /// Low-contrast borders that separate panels without drawing attention to
        /// themselves.
        static let hairline = adaptiveColor("DS.hairline", light: 0xDAD5C9, dark: 0x2A2824)

        /// "Recording", and nothing else. See rule 1 on `DS`.
        static let accent = adaptiveColor("DS.accent", light: 0xD8584A, dark: 0xE06A5C)

        /// Level-meter low end. Meter colours only; see rule 2 on `DS`.
        static let meterLow = adaptiveColor("DS.meterLow", light: 0x5F8F63, dark: 0x6FA173)
        /// Level-meter high end. Meter colours only; see rule 2 on `DS`.
        static let meterHigh = adaptiveColor("DS.meterHigh", light: 0xC99A3B, dark: 0xD9AC4D)

        /// A subtle tint of `ink`, for selected rows and highlighted text ranges.
        static let selection = adaptiveColor(
            "DS.selection", light: 0x1C1B18, dark: 0xEDEAE3, lightAlpha: 0.08, darkAlpha: 0.10
        )
    }
}

/// Builds a `SwiftUI.Color` that resolves `light` under aqua appearance and `dark` under
/// dark appearance, per §6.14's mandate to adapt colours via
/// `Color(nsColor: NSColor(name:dynamicProvider:))` rather than a static asset-catalogue
/// colour. Recomputed on each access (no cached static state), which keeps every `DS.Color`
/// token a plain, uncached `Sendable` value.
private func adaptiveColor(
    _ name: String,
    light: UInt32,
    dark: UInt32,
    lightAlpha: CGFloat = 1,
    darkAlpha: CGFloat = 1
) -> SwiftUI.Color {
    let dynamic = NSColor(name: NSColor.Name(name)) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(sottoHex: dark, alpha: darkAlpha)
            : NSColor(sottoHex: light, alpha: lightAlpha)
    }
    return SwiftUI.Color(nsColor: dynamic)
}

private extension NSColor {
    /// Convenience for the hex literals in `DS.Color`. Not exposed outside this file; the
    /// rest of the app reaches colours only through `DS.Color`.
    convenience init(sottoHex hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Space

extension DS {
    /// Spacing scale, in points. Every padding, spacing and offset in the app comes from
    /// this ladder.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 32
    }
}

// MARK: - Radius

extension DS {
    /// Corner radii. Flat fills plus hairline borders give depth, not shadows.
    enum Radius {
        static let control: CGFloat = 6
        static let panel: CGFloat = 10
        static let hud: CGFloat = 22
    }
}

// MARK: - Font

extension DS {
    /// Type scale. All sizes are the system font; `readout` additionally fixes tabular
    /// (monospaced) digits and a slightly heavier weight, since it is the only token used
    /// for a live-updating counter, where digit widths must not jitter.
    enum Font {
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        /// Tabular numerals, slightly heavier than `body`: elapsed-time and process-time
        /// counters.
        static let readout = SwiftUI.Font.system(size: 15, weight: .semibold).monospacedDigit()
    }
}

// MARK: - Border

extension DS {
    /// Line weights for strokes.
    enum Border {
        static let hairline: CGFloat = 1
    }
}

// MARK: - Motion

extension DS {
    /// Animation durations, in seconds. No motion in Sotto reaches for a value outside
    /// this list.
    enum Motion {
        static let quick: Double = 0.12
        static let panel: Double = 0.2
        static let hud: Double = 0.16

        // Not named in §6.14; added by batch B2. The period, in seconds, of one ripple
        // cycle through the HUD's level meter bars.
        /// Seconds per ripple cycle for the HUD meter's phase animation.
        static let hudMeterCycle: Double = 0.9
    }
}

// MARK: - Metric

extension DS {
    /// One-off numeric constants that are not spacing, radius, font or duration: window and
    /// HUD dimensions, bar counts, and similar layout facts named in §6.14.
    enum Metric {
        static let hudWidth: CGFloat = 340
        static let hudHeight: CGFloat = 76
        static let hudBottomOffset: CGFloat = 96
        static let hudBarCount: Int = 12
        static let hudBarFloor: CGFloat = 3
        static let hudBarWidth: CGFloat = 3
        static let hudBarSpacing: CGFloat = 3
        static let meterBarCount: Int = 12
        static let windowDefaultWidth: CGFloat = 860
        static let windowDefaultHeight: CGFloat = 620
        static let windowMinWidth: CGFloat = 720
        static let windowMinHeight: CGFloat = 520
        static let copiedFeedbackSeconds: Double = 1.4

        // Not named in §6.14; added for TokenSheet's own layout per that section's
        // instruction to add a token rather than inline a number ("add the token, such as
        // DS.Metric.swatchSize"). Reported to the orchestrator alongside every other token.
        /// Side length of a colour swatch square in `TokenSheet`.
        static let swatchSize: CGFloat = 44
        /// Width of the name column in a `TokenSheet` row, wide enough for the longest
        /// token name in any section.
        static let tokenSheetLabelWidth: CGFloat = 132
        /// Height of the bar `TokenSheet` draws to visualise each `Space` value.
        static let tokenSheetBarHeight: CGFloat = 10

        // Not named in §6.14; added by batch B2 for the HUD's level meter.
        /// Peak height a HUD meter bar reaches at full level; bars rest at `hudBarFloor`
        /// between peaks and when the meter is inactive.
        static let hudBarMaxHeight: CGFloat = 22
    }
}

// MARK: - Material

extension DS {
    /// System materials. Added by batch B2: §6.14 calls for "the HUD's material background"
    /// as the one deliberate exception to "no blur-heavy glass"; every other surface in the
    /// app is a flat `DS.Color` fill. Kept here, not inlined in `HUDView`, for the same
    /// reason every other visual constant lives in `DS`.
    enum Material {
        static let hud: SwiftUI.Material = .regularMaterial
    }
}
