import AVFoundation

/// The audio every engine takes, and the recorder and file decoder produce: 16 kHz mono Float32 samples.
public enum Audio {
    public static let sampleRate = 16_000
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
    )!

    public static func seconds(_ sampleCount: Int) -> Double { Double(sampleCount) / Double(sampleRate) }
    public static func sampleCount(_ seconds: Double) -> Int { Int(seconds * Double(sampleRate)) }
}
