import Testing
@testable import ParloCore

@Suite struct StyleResolverTests {
    @Test func overrideBeatsDefault() {
        #expect(StyleResolver.style(for: "com.apple.mail", overrides: ["com.apple.mail": .casual]) == .casual)
    }

    @Test(arguments: [
        ("com.apple.mail", Style.formal),
        ("com.microsoft.Outlook", .formal),
        ("com.tinyspeck.slackmacgap", .casual),
        ("com.hnc.Discord", .casual),
        ("com.apple.MobileSMS", .veryCasual),
        ("net.whatsapp.WhatsApp", .veryCasual),
        ("com.todesktop.230313mzl4w4u92", .technical),
        ("com.apple.dt.Xcode", .technical),
        ("com.apple.Terminal", .technical),
        ("com.microsoft.VSCode", .technical),
        ("com.unknown.app", .neutral),
    ])
    func defaults(bundleID: String, expected: Style) {
        #expect(StyleResolver.style(for: bundleID, overrides: [:]) == expected)
    }

    @Test func nilIsNeutral() {
        #expect(StyleResolver.style(for: nil, overrides: [:]) == .neutral)
    }
}
