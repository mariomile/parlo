/// Live text while recording: about once a second the tail of the audio captured so far is transcribed
/// with the active model and shown in the HUD. Display only: the pasted text comes from the dictation pipeline.
public enum LivePreview {
    public static let interval: Double = 1
    /// Only the last seconds are transcribed, so a preview costs the same at minute ten as at second ten.
    /// The HUD shows about one line, a few seconds of speech.
    public static let windowSeconds: Double = 10

    /// Slower models would keep the GPU busy for the whole recording and hold up the final transcription.
    public static func supports(_ info: ModelInfo) -> Bool {
        info.speed >= 4
    }
}
