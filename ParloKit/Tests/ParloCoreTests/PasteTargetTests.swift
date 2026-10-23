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
    }

    @Test func appsThatDontAnswerStillGetThePaste() {
        #expect(PasteTarget.acceptsText(.unknown))
    }
}
