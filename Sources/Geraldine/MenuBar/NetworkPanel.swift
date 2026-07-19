import SwiftUI

// MARK: - Connected devices card

/// Peripherals attached to this Mac — external drives, Bluetooth gear, USB iPhones/iPads.
/// The Wi-Fi connection itself remains a reorderable metric widget.
struct DevicesCard: View {
    @EnvironmentObject var devices: DeviceMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAll = false

    private let collapsedLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header

            WorkflowPhaseHost(phase: phase) {
                phaseContent
            }

            if devices.devices.count > collapsedLimit {
                Button {
                    withAnimation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion)) {
                        showAll.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(showAll ? "Show Less" : "Show \(devices.devices.count - collapsedLimit) More")
                        Image(systemName: showAll ? "chevron.up" : "chevron.down")
                    }
                }
                .buttonStyle(.quiet(Theme.accent))
                .font(.caption2.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.sm)
        .background(Theme.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 1)
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch phase {
        case .scanning:
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Looking For Devices…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        case .empty:
            Label("No External Devices", systemImage: "cable.connector.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        case .devices:
            VStack(spacing: 2) {
                ForEach(visible) { device in
                    DeviceRow(
                        device: device,
                        error: devices.ejectError(for: device),
                        ejecting: devices.isEjecting(device)
                    ) {
                        devices.eject(device)
                    }
                    .transition(rowTransition)
                }
            }
            .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion),
                       value: visible.map(\.id))
        }
    }

    private var visible: [ConnectedDevice] {
        showAll ? devices.devices : Array(devices.devices.prefix(collapsedLimit))
    }

    private var phase: DeviceContentPhase {
        if devices.devices.isEmpty { return devices.scanning ? .scanning : .empty }
        return .devices
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .center))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "cable.connector.horizontal")
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text("Connected Devices")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if devices.scanning, !devices.devices.isEmpty {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Refreshing connected devices")
            }
            if !devices.devices.isEmpty {
                AnimatedNumberText("\(devices.devices.count)", value: Double(devices.devices.count))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum DeviceContentPhase: Hashable {
    case scanning
    case empty
    case devices
}

private struct DeviceRow: View {
    let device: ConnectedDevice
    let error: String?
    let ejecting: Bool
    let eject: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.xs) {
                ModuleGlyph(systemImage: device.kind.icon, tint: identityTint, size: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(device.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let battery = device.battery {
                    DeviceBatteryIndicator(level: battery)
                }

                if device.ejectable {
                    Button(action: eject) {
                        Group {
                            if ejecting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "eject.fill")
                            }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.quiet(identityTint))
                    .minimumHitArea()
                    .disabled(ejecting)
                    .help(ejecting ? "Ejecting \(device.name)" : "Eject \(device.name)")
                    .accessibilityLabel(ejecting ? "Ejecting \(device.name)" : "Eject \(device.name)")
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.bad)
                    .lineLimit(2)
                    .padding(.leading, 38)
                    .accessibilityLabel("Eject error")
                    .accessibilityValue(error)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill(error != nil ? Theme.bad.opacity(0.08)
                      : (isHovered ? identityTint.opacity(0.07) : Color.clear))
        }
        .onHover { isHovered = $0 }
        .geraldineAnimation(.quick, value: isHovered)
        .geraldineAnimation(.standard, value: error)
    }

    private var identityTint: Color {
        switch device.kind {
        case .drive: Theme.aqua
        case .iosDevice: Theme.indigo
        case .bluetooth: Theme.accent2
        }
    }
}

private struct DeviceBatteryIndicator: View {
    let level: Double

    private var clampedLevel: Double { min(1, max(0, level)) }
    private var tint: Color {
        MetricPresentationPolicy.batteryReadoutColor(level: clampedLevel)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            AnimatedNumberText("\(Int((clampedLevel * 100).rounded()))%", value: clampedLevel * 100)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * clampedLevel)
                    }
            }
            .frame(width: 32, height: 3)
            .geraldineAnimation(.standard, value: clampedLevel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue("\(Int((clampedLevel * 100).rounded())) percent")
    }
}
