import ParloCore
import SwiftUI

extension HistoryEntry {
    /// What a row shows: the text, or why there is none, dimmed.
    var statusLine: (text: String, dimmed: Bool) {
        switch status {
        case .done: (text ?? "", false)
        case .processing: ("Transcribing…", true)
        case .nothingHeard: ("Nothing heard", true)
        case let .failed(reason): ("Failed: \(reason)", true)
        }
    }
}

/// A length such as "1m 5s".
func formattedDuration(_ seconds: Double) -> String {
    Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
}

/// Copies, then shows a checkmark for a moment. `label` draws the icon it is given.
struct CopyButton<Label: View>: View {
    let copy: () -> Void
    @ViewBuilder let label: (_ icon: String) -> Label
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            label(copied ? "checkmark" : "doc.on.doc")
        }
        .help("Copy")
    }
}
