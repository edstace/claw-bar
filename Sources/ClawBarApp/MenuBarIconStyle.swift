import Foundation

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case bridge = "bridge"
    case claw = "claw"
    case wave = "wave"
    case paw = "paw"

    static let defaultsKey = "clawbar.settings.menuBarIconStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bridge:
            return "Bridge"
        case .claw:
            return "Claw"
        case .wave:
            return "Wave"
        case .paw:
            return "Paw"
        }
    }

    var imageName: String {
        switch self {
        case .bridge:
            return "ClawBarTemplateBridge"
        case .claw:
            return "ClawBarTemplateClaw"
        case .wave:
            return "ClawBarTemplateWave"
        case .paw:
            return "ClawBarTemplatePaw"
        }
    }

    static var current: MenuBarIconStyle {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let style = MenuBarIconStyle(rawValue: raw)
        {
            return style
        }
        return .paw
    }
}
