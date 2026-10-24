import AppKit
import ParloCore
import SwiftUI
import UniformTypeIdentifiers

/// Every kept dictation: search, copy, paste back, retry, delete, export, and audio files to transcribe.
struct HistoryView: View {
    @Bindable var controller: AppController
    @State private var query = ""
    @State private var dropTargeted = false

    private var shown: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return controller.recent }
        return controller.recent.filter {
            if $0.text?.localizedCaseInsensitiveContains(q) == true { return true }
            if case let .file(name, _) = $0.kind { return name.localizedCaseInsensitiveContains(q) }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatsHeader(stats: HistoryStats(controller.recent))
            Divider()
            if let error = controller.historySaveError {
                Label("History can't be saved to disk: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            toolbar
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(
                    controller.recent.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: controller.recent.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(controller.recent.isEmpty ? "Hold fn to dictate, or drop an audio file here." : "")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(shown) { entry in
                    HistoryRow(entry: entry, progress: controller.fileProgress[entry.id], controller: controller)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(.tint.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(controller.transcribeFile)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Transcribe File…", systemImage: "waveform.badge.plus", action: chooseFiles)
                Button("Export…", systemImage: "square.and.arrow.up", action: export)
                    .disabled(controller.recent.isEmpty)
            }
            Text("Drop an audio file here to transcribe it with the active model.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose audio files to transcribe"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(controller.transcribeFile)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Parlo history.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HistoryExport.markdown(controller.recent).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct StatsHeader: View {
    let stats: HistoryStats

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                stat(stats.words.formatted(), "words dictated")
                stat(stats.dictations.formatted(), "dictations")
                stat(formattedDuration(stats.speakingSeconds), "speaking time")
                stat(formattedDuration(stats.timeSavedSeconds), "time saved")
            }
            Text("Time saved compares speaking with typing the same words at \(Int(HistoryStats.typingWordsPerMinute)) words per minute.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let progress: Double?
    let controller: AppController

    private var isFile: Bool {
        if case .file = entry.kind { true } else { false }
    }

    var body: some View {
        let label = entry.statusLine
        return
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.text)
                    .font(.system(size: 13))
                    .foregroundStyle(label.dimmed ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.status == .processing, isFile {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                }
                Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(formattedDuration(entry.duration)) · \(entry.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                if entry.text != nil {
                    CopyButton(copy: { controller.copy(entry) }, label: icon)
                        .buttonStyle(.borderless)
                    button("text.insert", "Paste into the previous app") { controller.paste(entry) }
                }
                if entry.canRetry && entry.status != .processing {
                    button("arrow.clockwise", entry.isFile ? "Transcribe the file again" : "Transcribe again and copy") {
                        controller.retry(entry)
                    }
                }
                button("trash", "Delete") { controller.delete(entry) }
            }
        }
        .padding(.vertical, 4)
    }

    private func button(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(name) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 24, height: 24)
    }
}
