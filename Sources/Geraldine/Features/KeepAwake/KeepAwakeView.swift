import SwiftUI

struct KeepAwakeView: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @State private var selectedDuration: KeepAwakeDuration = .oneHour

    private var tint: Color { Module.keepAwake.tint }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .keepAwake) {
                Button {
                    keepAwake.toggle()
                } label: {
                    Label(keepAwake.isActive ? "Deactivate" : "Activate",
                          systemImage: keepAwake.isActive ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(keepAwake.isActive ? Theme.bad : tint)
            }

            ScrollView {
                VStack(spacing: 16) {
                    hero
                    durationCard
                    policyCard
                    automationCard
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectedDuration = keepAwake.defaultDuration }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            Button {
                keepAwake.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(keepAwake.isActive ? Theme.bad.opacity(0.08) : Color.primary.opacity(0.04))
                    EyeView(isActive: keepAwake.isActive, size: 104)
                }
                .frame(width: 116, height: 116)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(keepAwake.isActive ? "Poke eyes to let your Mac sleep." : "Poke eyes to keep awake.")

            VStack(alignment: .leading, spacing: 6) {
                Text(keepAwake.isActive ? "Awake" : "Idle Sleep Allowed")
                    .font(.rounded(34, .bold))
                    .foregroundStyle(keepAwake.isActive ? tint : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(keepAwake.statusLine)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if keepAwake.isActive {
                    Text(keepAwake.endTimeLine)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                } else if let error = keepAwake.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
            }

            Spacer()
        }
        .card()
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Duration")
                Spacer()
                Button {
                    keepAwake.activate(option: selectedDuration)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    Button {
                        selectedDuration = duration
                        keepAwake.defaultDuration = duration
                    } label: {
                        VStack(spacing: 3) {
                            Text(duration.shortLabel)
                                .font(.rounded(18, .bold))
                            Text(duration.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(duration == selectedDuration ? tint.opacity(0.18) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(duration == selectedDuration ? tint.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Power")

            Toggle(isOn: $keepAwake.allowDisplaySleep) {
                Label("Allow Display Sleep", systemImage: "display")
            }
            Toggle(isOn: $keepAwake.deactivateOnBattery) {
                Label("Deactivate On Battery", systemImage: "battery.25")
            }
            Toggle(isOn: $keepAwake.pauseWhenScreenLocked) {
                Label("Pause While Screen Is Locked", systemImage: "lock.display")
            }
        }
        .toggleStyle(.switch)
        .card()
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Automation")

            VStack(alignment: .leading, spacing: 8) {
                Label("geraldine:activate?minutes=10", systemImage: "link")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    commandPill("activate")
                    commandPill("deactivate")
                    commandPill("toggle")
                    Spacer()
                }
            }
        }
        .card()
    }

    private func commandPill(_ command: String) -> some View {
        Text(command)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}
