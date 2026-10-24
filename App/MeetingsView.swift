import AppKit
import ParloCore
import SwiftUI
import UniformTypeIdentifiers

/// Every recorded meeting: its notes, its transcript, and the controls to start one, copy, export or redo it.
struct MeetingsView: View {
    @Bindable var meetings: MeetingController
    let start: () -> Void
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(meetings.meetings, selection: $selection) { meeting in
                MeetingListRow(meeting: meeting, recording: meeting.id == meetings.recordingID).tag(meeting.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { recordButton.padding(10) }
            .safeAreaInset(edge: .top) {
                if let error = meetings.store.saveError {
                    Label("Changes couldn't be saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(10)
                }
            }
        } detail: {
            if let id = selection ?? meetings.meetings.first?.id, let meeting = meetings.store.meeting(id) {
                MeetingDetail(meeting: meeting, controller: meetings)
            } else {
                ContentUnavailableView(
                    "No meetings yet", systemImage: "person.2.wave.2",
                    description: Text("Start one when a call begins. Parlo records your microphone and what the Mac plays, transcribes both on this Mac, then writes the notes with the model chosen in Settings → AI.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private var recordButton: some View {
        Group {
            if meetings.isRecording {
                Button("Stop Meeting", systemImage: "stop.circle.fill") { meetings.stop() }
                    .tint(.red)
            } else {
                Button("Start Meeting", systemImage: "record.circle", action: start)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }
}

private struct MeetingListRow: View {
    let meeting: Meeting
    let recording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) {
                if recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Recording")
                } else {
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    if meeting.duration > 0 { Text("· \(MeetingTranscript.timestamp(meeting.duration))") }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    let controller: MeetingController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                status
                if let notes = meeting.notes {
                    NotesText(markdown: notes)
                    Text("Written by AI from the transcript. It can be wrong, so check what matters.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if !meeting.turns.isEmpty {
                    Divider()
                    Text("Transcript").font(.headline)
                    ForEach(Array(meeting.turns.enumerated()), id: \.offset) { _, turn in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(MeetingTranscript.timestamp(turn.start))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .trailing)
                            Text(turn.speaker.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(turn.speaker == .me ? Color.accentColor : .orange)
                                .frame(width: 40, alignment: .leading)
                            Text(turn.text).font(.system(size: 13)).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("\(meeting.date.formatted(date: .complete, time: .shortened)) · \(MeetingTranscript.timestamp(meeting.duration))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.status != .recording {
                HStack(spacing: 4) {
                    CopyButton(copy: { controller.copy(meeting) }) { name in Image(systemName: name).frame(width: 24, height: 24) }
                        .help("Copy notes and transcript as Markdown")
                    button("square.and.arrow.up", "Export as Markdown", action: export)
                    if meeting.hasAudio && meeting.status != .processing {
                        button("arrow.clockwise", "Transcribe again and write new notes") { controller.process(meeting.id) }
                    }
                    button("trash", "Delete the meeting and its recordings") { controller.delete(meeting.id) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch meeting.status {
        case .recording:
            Label("Recording. Stop the meeting to get the transcript and notes.", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        case .processing:
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcribing and writing the notes…").foregroundStyle(.secondary)
                ProgressView(value: controller.progress[meeting.id]).frame(maxWidth: 280)
            }
        case let .failed(reason):
            banner("\(reason). \(meeting.hasAudio ? "Use ↻ to process it again." : "")", "exclamationmark.triangle.fill", .orange)
        case .done:
            if meeting.turns.isEmpty { banner("Nothing was heard in this meeting.", "waveform.slash", .secondary) }
        }
        if meeting.othersSilent, meeting.status == .done {
            banner(
                "Nothing came from the Mac's audio, so only your side is here. If the call had sound, allow Parlo in System Settings → Privacy & Security → Screen & System Audio Recording, under System Audio Recording Only.",
                "speaker.slash.fill", .orange
            )
        }
        if let error = meeting.notesError {
            banner(meeting.notes == nil ? "No notes: \(error)" : error, "sparkles", .orange)
        }
    }

    private func banner(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func button(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 24, height: 24) }
            .help(help)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.displayTitle).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try meeting.markdown.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}

/// The notes' Markdown, line by line: headings, checkbox items and inline bold or italics.
private struct NotesText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line.trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        if line.isEmpty {
            EmptyView()
        } else if line.hasPrefix("#") {
            Text(inline(String(line.drop { $0 == "#" || $0 == " " }))).font(.headline).padding(.top, 6)
        } else if let item = line.firstMatch(of: #/^[-*] \[( |x|X)\] (.*)$/#) {
            Label { Text(inline(String(item.2))) } icon: { Image(systemName: item.1 == " " ? "square" : "checkmark.square") }
        } else if let item = line.firstMatch(of: #/^[-*] (.*)$/#) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(item.1)))
            }
        } else {
            Text(inline(line))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
