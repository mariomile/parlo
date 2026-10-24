/// Whether the focused element can take a paste, from what Accessibility reports about it.
public enum PasteTarget {
    public enum Focus: Equatable, Sendable {
        /// Accessibility says nothing has keyboard focus (desktop, a window with no field).
        case nothing
        /// The app didn't answer (many Electron apps): assume it can, as before.
        case unknown
        case element(role: String?, hasTextSelection: Bool, valueSettable: Bool)
    }

    /// Roles that never take typed text. Everything else gets the paste: Electron apps and terminals
    /// report real input areas as windows, groups or web areas, and a slow app may not report a role at all.
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle",
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXImage", "AXSlider", "AXTabGroup", "AXToolbar",
        "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXMenuItem", "AXLink",
    ]

    public static func acceptsText(_ focus: Focus) -> Bool {
        switch focus {
        case .nothing: false
        case .unknown: true
        case let .element(role, hasTextSelection, valueSettable):
            hasTextSelection || valueSettable || !(role.map(nonTextRoles.contains) ?? false)
        }
    }
}
