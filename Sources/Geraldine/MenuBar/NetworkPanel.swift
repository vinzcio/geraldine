import SwiftUI

// MARK: - Connected devices card

/// Peripherals attached to this Mac — external drives, Bluetooth gear, USB iPhones/iPads.
/// (The Wi-Fi connection itself is a reorderable metric widget; see MetricWidgets.swift.)
struct DevicesCard: View {
    @EnvironmentObject var devices: DeviceMonitor
    @State private var showAll = false

    private let collapsedLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if devices.devices.isEmpty {
                Text(devices.scanning ? "Looking for devices…" : "No external devices")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(visible) { device in
                    DeviceRow(device: device) { devices.eject(device) }
                }
                if devices.devices.count > collapsedLimit {
                    Button(showAll ? "Show less" : "Show \(devices.devices.count - collapsedLimit) more") {
                        withAnimation(.snappy(duration: 0.2)) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var visible: [ConnectedDevice] {
        showAll ? devices.devices : Array(devices.devices.prefix(collapsedLimit))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "cable.connector.horizontal").font(.caption).foregroundStyle(Theme.accent)
            Text("Connected Devices").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            if !devices.devices.isEmpty {
                AnimatedNumberText("\(devices.devices.count)", value: Double(devices.devices.count))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: ConnectedDevice
    let eject: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: device.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(device.lowBattery ? Theme.bad : Theme.accent2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(device.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let battery = device.battery {
                AnimatedNumberText("\(Int((battery * 100).rounded()))%", value: battery * 100)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(device.lowBattery ? Theme.bad : .secondary)
            }
            if device.ejectable {
                Button(action: eject) { Image(systemName: "eject.fill").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Eject \(device.name)")
            }
        }
    }
}
