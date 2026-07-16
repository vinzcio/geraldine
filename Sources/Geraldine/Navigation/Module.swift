import SwiftUI

/// Declaration order is the sidebar order (groups filter it top to bottom) and
/// drives `navigationIndex`, so the detail slide direction matches what the
/// user sees. Keep new cases in their visual position.
enum Module: String, CaseIterable, Identifiable {
    case dashboard
    case smartCare
    case activity
    case storage
    case battery
    case keepAwake
    case calendar
    case cleanup
    case largeFiles
    case uninstaller
    case powerTools
    case privacy
    case loginItems
    case maintenance
    case updater
    case permissions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:   return "Dashboard"
        case .smartCare:   return "Smart Care"
        case .activity:    return "Activity"
        case .storage:     return "Storage"
        case .battery:     return "Battery"
        case .keepAwake:   return "Keep Awake"
        case .calendar:    return "Calendar & Clocks"
        case .powerTools:  return "Power Tools"
        case .cleanup:     return "Cleanup"
        case .largeFiles:  return "Large & Old Files"
        case .uninstaller: return "Uninstaller"
        case .privacy:     return "Privacy"
        case .loginItems:  return "Login Items"
        case .maintenance: return "Maintenance"
        case .updater:     return "Updater"
        case .permissions: return "Permissions"
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
        case .keepAwake:   return "eye.fill"
        case .calendar:    return "calendar"
        case .powerTools:  return "bolt.horizontal.circle.fill"
        case .cleanup:     return "sparkles"
        case .largeFiles:  return "doc.text.magnifyingglass"
        case .uninstaller: return "trash"
        case .privacy:     return "hand.raised.fill"
        case .loginItems:  return "power"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .updater:     return "arrow.triangle.2.circlepath"
        case .permissions: return "lock.shield.fill"
        case .settings:    return "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard:   return Theme.accent
        case .smartCare:   return Theme.accent
        case .activity:    return Theme.accent2
        case .storage:     return Theme.mint
        case .battery:     return Theme.green
        case .keepAwake:   return Theme.orange
        case .calendar:    return Theme.indigo
        case .powerTools:  return Theme.indigo
        case .cleanup:     return Theme.accent2
        case .largeFiles:  return Theme.orange
        case .uninstaller: return Theme.rose
        case .privacy:     return Theme.aqua
        case .loginItems:  return Theme.indigo
        case .maintenance: return Theme.green
        case .updater:     return Theme.accent2
        case .permissions: return Theme.accent2
        case .settings:    return Color.secondary
        }
    }

    var navigationIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    var subtitle: String {
        switch self {
        case .dashboard:   return "Live system vitals at a glance"
        case .smartCare:   return "One-tap health check and guided next steps"
        case .activity:    return "CPU, memory & top processes"
        case .storage:     return "What's using your disk"
        case .battery:     return "Charge history, consumers & health"
        case .keepAwake:   return "Prevent idle sleep and display dimming"
        case .calendar:    return "Month calendar, world clocks & date format"
        case .powerTools:  return "Dock, window, keyboard, and Finder controls"
        case .cleanup:     return "Clear caches, logs, and junk"
        case .largeFiles:  return "Find big and forgotten files"
        case .uninstaller: return "Remove apps and their leftovers"
        case .privacy:     return "Clear browsing data and traces"
        case .loginItems:  return "Manage other apps and helpers that start up"
        case .maintenance: return "Run macOS upkeep tasks"
        case .updater:     return "Find apps that are out of date"
        case .permissions: return "Access Geraldine needs to do its job"
        case .settings:    return "Appearance, behavior, access, and startup"
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
        case .dashboard, .smartCare, .activity, .storage, .battery, .keepAwake, .calendar: return .overview
        case .cleanup, .largeFiles, .uninstaller: return .clean
        case .powerTools, .privacy, .loginItems, .maintenance, .updater, .permissions, .settings: return .tune
        }
    }

    static func modules(in group: Group) -> [Module] {
        allCases.filter { $0.group == group }
    }
}
