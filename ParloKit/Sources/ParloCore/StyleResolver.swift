public enum StyleResolver {
    public static let defaults: [String: Style] = [
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.tinyspeck.slackmacgap": .casual,
        "com.hnc.Discord": .casual,
        "com.microsoft.teams2": .casual,
        "com.apple.MobileSMS": .veryCasual,
        "net.whatsapp.WhatsApp": .veryCasual,
        "ru.keepcoder.Telegram": .veryCasual,
        "com.todesktop.230313mzl4w4u92": .technical, // Cursor
        "com.apple.dt.Xcode": .technical,
        "com.apple.Terminal": .technical,
        "com.googlecode.iterm2": .technical,
        "com.microsoft.VSCode": .technical,
        "dev.warp.Warp-Stable": .technical,
    ]

    public static func style(for bundleID: String?, overrides: [String: Style]) -> Style {
        guard let bundleID else { return .neutral }
        return overrides[bundleID] ?? defaults[bundleID] ?? .neutral
    }
}
