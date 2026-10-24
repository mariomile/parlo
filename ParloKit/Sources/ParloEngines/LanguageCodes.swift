/// Engines that want a region with the language ("it-IT"): Nemotron prompt IDs, Apple Speech locales.
enum LanguageCodes {
    /// The usual region for a bare language code, so "it" means it-IT rather than it-CH.
    static func regional(_ code: String?) -> String? {
        guard let code else { return nil }
        let regions = ["en": "en-US", "es": "es-ES", "fr": "fr-FR", "it": "it-IT", "pt": "pt-BR",
                       "de": "de-DE", "zh": "zh-CN", "ja": "ja-JP"]
        return regions[code] ?? code
    }
}
