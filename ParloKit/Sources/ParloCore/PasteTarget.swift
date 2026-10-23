/// Whether the focused element can take a paste, from what Accessibility reports about it.
public enum PasteTarget {
    public enum Focus: Equatable, Sendable {
        /// Accessibility says nothing has keyboard focus (desktop, a window with no field).
        case nothing
        /// The app didn't answer (many Electron apps): assume it can, as before.
        case unknown
        case element(role: String?, hasTextSelection: Bool, valueSettable: Bool)
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    public static func acceptsText(_ focus: Focus) -> Bool {
        switch focus {
        case .nothing: false
        case .unknown: true
        case let .element(role, hasTextSelection, valueSettable):
            hasTextSelection || valueSettable || role.map(textRoles.contains) == true
        }
    }
}
