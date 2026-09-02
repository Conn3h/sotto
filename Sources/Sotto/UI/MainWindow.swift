import SwiftUI

/// The main window (spec §6.14): a transport strip for button-triggered recording, then a
/// History / Dictionary tab area. Hosted by the `Window("Sotto", id: "main")` scene in
/// `SottoApp`.
@MainActor
struct MainWindow: View {
    let controller: DictationController

    private enum Tab: Hashable {
        case history
        case dictionary
    }

    @State private var tab: Tab = .history

    var body: some View {
        VStack(spacing: DS.Space.none) {
            TransportStrip(controller: controller)
                .padding(DS.Space.panel)

            Rectangle()
                .fill(DS.Color.hairline)
                .frame(height: DS.Border.hairline)

            VStack(spacing: DS.Space.none) {
                SegmentedChoice(options: [Tab.history, .dictionary], selection: $tab) { option in
                    switch option {
                    case .history: "History"
                    case .dictionary: "Dictionary"
                    }
                }
                .padding(DS.Space.roomy)

                Group {
                    switch tab {
                    case .history:
                        HistoryPanel()
                    case .dictionary:
                        DictionaryPanel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Color.ground)
    }
}

/// Record/Stop, the recording lamp, the live level meter, and the elapsed-time readout.
@MainActor
private struct TransportStrip: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.base) {
                Circle()
                    .fill(controller.state.isActive ? DS.Color.accent : DS.Color.inkTertiary)
                    .frame(width: DS.Metric.lampSize, height: DS.Metric.lampSize)
                    .accessibilityLabel(controller.state.isActive ? "Recording" : "Not recording")

                Button {
                    if controller.state.isActive {
                        controller.stopButtonRecording()
                    } else {
                        controller.startButtonRecording()
                    }
                } label: {
                    Text(controller.state.isActive ? "Stop" : "Record")
                        .frame(minWidth: DS.Metric.keycapMinWidth)
                }
                .buttonStyle(TransportButtonStyle(isActive: controller.state.isActive))

                LevelMeterView(level: controller.level, isActive: controller.state.isActive)

                Spacer(minLength: DS.Space.roomy)

                ElapsedReadout(holdStartedAt: controller.holdStartedAt, isActive: controller.state.isActive)
            }

            Text("Recordings started here are saved to History, not typed.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkTertiary)
        }
    }
}

/// Flat fills only: `DS.Color.accent` while recording (the button's one other permitted use
/// of the recording colour, alongside the lamp), `panelRaised` otherwise, darkening to
/// `panel` while pressed.
@MainActor
private struct TransportButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.label)
            .foregroundStyle(isActive ? DS.Color.panel : DS.Color.ink)
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.snug)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
            )
    }

    private func fill(pressed: Bool) -> SwiftUI.Color {
        if isActive {
            return DS.Color.accent
        }
        return pressed ? DS.Color.panel : DS.Color.panelRaised
    }
}

/// Tabular-digit `mm:ss.t` elapsed time, ticking from `holdStartedAt` while active and
/// resting at zero otherwise.
@MainActor
private struct ElapsedReadout: View {
    let holdStartedAt: Date?
    let isActive: Bool

    private static let idleText = "00:00.0"
    private static let locale = Locale(identifier: "en_US_POSIX")

    var body: some View {
        TimelineView(.periodic(from: .now, by: DS.Motion.elapsedTick)) { context in
            Text(text(now: context.date))
                .font(DS.Font.readout)
                .foregroundStyle(DS.Color.ink)
        }
    }

    private func text(now: Date) -> String {
        guard isActive, let holdStartedAt else {
            return Self.idleText
        }
        let elapsed = max(0, now.timeIntervalSince(holdStartedAt))
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let tenths = Int((elapsed - elapsed.rounded(.down)) * 10)
        return String(format: "%02d:%02d.%d", locale: Self.locale, minutes, seconds, tenths)
    }
}
