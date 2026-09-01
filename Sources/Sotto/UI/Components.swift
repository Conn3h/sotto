import SwiftUI

/// Shared pieces for the C1 app shell, built fresh on top of `DS` (spec §6.14). Nothing here
/// reads `HUDView`'s private types — that view's meter is HUD-only, so `LevelMeterView`
/// below is a separate implementation sharing only its design tokens.

// MARK: - Panel

/// A flat surface with a hairline border: the container every card, section and row group
/// in the app shell sits on.
@MainActor
struct Panel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(DS.Space.roomy)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Color.panel))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Section header

/// A quiet, uppercase label that introduces a group of controls.
@MainActor
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
    }
}

// MARK: - Search field

/// A single-line search box with a leading glyph and a clear button, styled as an inset
/// field rather than the system search field so it matches the rest of the chrome.
@MainActor
struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Color.inkTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.panelRaised))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
        )
    }
}

// MARK: - Chip

/// A small rounded badge for metadata: engine names, source labels, correction summaries.
@MainActor
struct Chip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .background(Capsule().fill(DS.Color.panelRaised))
            .overlay(Capsule().stroke(DS.Color.hairline, lineWidth: DS.Border.hairline))
    }
}

// MARK: - Empty state

/// A centred glyph and two lines of text for a panel with nothing in it yet.
@MainActor
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Metric.emptyStateIconSize))
                .foregroundStyle(DS.Color.inkTertiary)
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.panel)
    }
}

// MARK: - Segmented choice

/// A keycap-style segmented control: flat pills in a recessed track, sharing one visual
/// family across every exclusive choice in the app shell — the History/Dictionary tabs, the
/// push-to-talk key picker, and the dictionary entry kind toggle. Selection uses
/// `DS.Color.selection`, the token spec §6.14 reserves for "selected rows and highlighted
/// text ranges."
@MainActor
struct SegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: DS.Space.hair) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(DS.Space.hair)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.ground))
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            selection = option
        } label: {
            Text(label(option))
                .font(DS.Font.label)
                .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkSecondary)
                .frame(minWidth: DS.Metric.keycapMinWidth)
                .padding(.horizontal, DS.Space.base)
                .padding(.vertical, DS.Space.snug)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .fill(isSelected ? DS.Color.selection : SwiftUI.Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .stroke(isSelected ? DS.Color.hairline : SwiftUI.Color.clear, lineWidth: DS.Border.hairline)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Level meter

/// The main window's level meter: `DS.Metric.meterBarCount` bars that light from
/// `DS.Color.meterLow` to `DS.Color.meterHigh` as `level` climbs, like a classic VU ladder.
/// This is a fresh implementation, written for the transport strip's own compact, glanceable
/// reading rather than the HUD's ripple (whose views are private to `HUDView`).
@MainActor
struct LevelMeterView: View {
    let level: Float
    let isActive: Bool

    private var litCount: Int {
        guard isActive else {
            return 0
        }
        let clamped = max(0, min(1, level))
        return Int((CGFloat(clamped) * CGFloat(DS.Metric.meterBarCount)).rounded())
    }

    var body: some View {
        HStack(spacing: DS.Metric.meterBarSpacing) {
            ForEach(0..<DS.Metric.meterBarCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(
                        width: DS.Metric.meterBarWidth,
                        height: index < litCount ? DS.Metric.meterBarMaxHeight : DS.Metric.meterBarFloor
                    )
            }
        }
        .frame(height: DS.Metric.meterBarMaxHeight, alignment: .bottom)
        .animation(.easeOut(duration: DS.Motion.quick), value: litCount)
    }

    private func color(for index: Int) -> SwiftUI.Color {
        guard index < litCount else {
            return DS.Color.hairline
        }
        let lastIndex = DS.Metric.meterBarCount - 1
        let position = lastIndex > 0 ? Double(index) / Double(lastIndex) : 0
        return DS.Color.meterLow.mix(with: DS.Color.meterHigh, by: position)
    }
}
