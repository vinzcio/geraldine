import SwiftUI

enum Module: String, CaseIterable, Identifiable {
    case dashboard
    case smartCare
    case activity
    case storage
    case battery
    case cleanup
    case largeFiles
    case spaceLens
    case uninstaller
    case privacy
    case loginItems
    case maintenance
    case updater
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .smartCare:   return "Smart Care"
        case .activity:    return "Activity"
        case .storage:     return "Storage"
        case .battery:     return "Battery"
        case .cleanup:     return "Cleanup"
        case .largeFiles:  return "Large & Old Files"
        case .spaceLens:   return "Space Lens"
        case .uninstaller: return "Uninstaller"
        case .privacy:     return "Privacy"
        case .loginItems:  return "Login Items"
        case .maintenance: return "Maintenance"
        case .updater:     return "Updater"
        case .settings:    return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:   return "gauge.with.dots.needle.50percent"
        case .smartCare:   return "checkmark.seal.fill"
        case .activity:    return "waveform.path.ecg"
        case .storage:     return "chart.pie.fill"
        case .battery:     return "battery.100"
        case .cleanup:     return "sparkles"
        case .largeFiles:  return "doc.text.magnifyingglass"
        case .spaceLens:   return "circle.hexagongrid.fill"
        case .uninstaller: return "trash"
        case .privacy:     return "hand.raised.fill"
        case .loginItems:  return "power"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .updater:     return "arrow.triangle.2.circlepath"
        case .settings:    return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard:   return Theme.accent
        case .smartCare:   return Theme.accent
        case .activity:    return Theme.accent2
        case .storage:     return Color(red: 0.20, green: 0.70, blue: 0.62)
        case .battery:     return Color(red: 0.30, green: 0.78, blue: 0.45)
        case .cleanup:     return Theme.accent2
        case .largeFiles:  return Color(red: 0.95, green: 0.55, blue: 0.35)
        case .spaceLens:   return Color(red: 0.86, green: 0.42, blue: 0.86)
        case .uninstaller: return Color(red: 0.96, green: 0.45, blue: 0.50)
        case .privacy:     return Color(red: 0.30, green: 0.74, blue: 0.74)
        case .loginItems:  return Color(red: 0.55, green: 0.60, blue: 0.98)
        case .maintenance: return Color(red: 0.40, green: 0.72, blue: 0.50)
        case .updater:     return Color(red: 0.50, green: 0.66, blue: 0.96)
        case .settings:    return Color.secondary
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard:   return "Live system vitals at a glance"
        case .smartCare:   return "One-tap health check & cleanup"
        case .activity:    return "CPU, memory & top processes"
        case .storage:     return "What's using your disk"
        case .battery:     return "Charge history, consumers & health"
        case .cleanup:     return "Clear caches, logs, and junk"
        case .largeFiles:  return "Find big and forgotten files"
        case .spaceLens:   return "See what's using your disk"
        case .uninstaller: return "Remove apps and their leftovers"
        case .privacy:     return "Clear browsing data and traces"
        case .loginItems:  return "Control what launches at startup"
        case .maintenance: return "Run macOS upkeep tasks"
        case .updater:     return "Find apps that are out of date"
        case .settings:    return "Choose where Geraldine appears"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case clean = "Clean"
        case tune = "Optimize"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .dashboard, .smartCare, .activity, .storage, .battery: return .overview
        case .cleanup, .largeFiles, .spaceLens, .uninstaller: return .clean
        case .privacy, .loginItems, .maintenance, .updater, .settings: return .tune
        }
    }

    static func modules(in group: Group) -> [Module] {
        allCases.filter { $0.group == group }
    }
}
