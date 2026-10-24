import Testing
@testable import ParloCore

@Suite struct PasteTargetTests {
    @Test func textFieldsTakeText() {
        #expect(PasteTarget.acceptsText(.element(role: "AXTextArea", hasTextSelection: false, valueSettable: false)))
        // Web pages report editable areas through a text selection rather than the role.
        #expect(PasteTarget.acceptsText(.element(role: "AXGroup", hasTextSelection: true, valueSettable: false)))
    }

    @Test func nothingFocusedOrNotEditable() {
        #expect(!PasteTarget.acceptsText(.nothing))
        #expect(!PasteTarget.acceptsText(.element(role: "AXList", hasTextSelection: false, valueSettable: false)))
        #expect(!PasteTarget.acceptsText(.element(role: "AXButton", hasTextSelection: false, valueSettable: false)))
    }

    @Test func appsThatDontAnswerStillGetThePaste() {
        #expect(PasteTarget.acceptsText(.unknown))
        // A busy app that answered the focus query but not the role one.
        #expect(PasteTarget.acceptsText(.element(role: nil, hasTextSelection: false, valueSettable: false)))
        // Electron apps and terminals focus a window, group or web area for their input.
        for role in ["AXWindow", "AXGroup", "AXWebArea", "AXScrollArea", "AXUnknown"] {
            #expect(PasteTarget.acceptsText(.element(role: role, hasTextSelection: false, valueSettable: false)))
        }
    }
}
