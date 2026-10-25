import ParloCore
import ParloEngines
import Testing

@Test func onlyOnDeviceProvidersKeepTextOnThisMac() {
    func settings(_ provider: LLMProvider, _ baseURL: String = "") -> LLMSettings {
        LLMSettings(enabled: false, provider: provider, baseURL: baseURL, model: "m")
    }
    #expect(settings(.apple).runsOnThisMac)
    #expect(settings(.local).runsOnThisMac)
    #expect(settings(.openAICompatible, "http://localhost:11434/v1").runsOnThisMac)
    #expect(settings(.openAICompatible, "http://[::1]:1234/v1").runsOnThisMac)
    #expect(settings(.openAICompatible, "http://LOCALHOST:1234/v1").runsOnThisMac)
    #expect(settings(.openAICompatible, " \nhttp://localhost:1234/v1 \n").runsOnThisMac)
    #expect(settings(.openAICompatible, "http://127.0.0.1:1234/v1").runsOnThisMac)
    #expect(!settings(.openAICompatible, "https://localhost.example.com/v1").runsOnThisMac)
    #expect(!settings(.openAICompatible, "https://localhost@remote.example/v1").runsOnThisMac)
    #expect(!settings(.openAICompatible, "file://localhost/model").runsOnThisMac)
    #expect(!settings(.openAICompatible, "https://api.groq.com/openai/v1").runsOnThisMac)
}
