import AppKit
import SwiftUI

@Observable
final class HUDModel {
    enum State: Equatable {
        case hidden
        case recording(command: Bool)
        case processing
        case message(String, isError: Bool)
    }

    var state: State = .hidden
    /// Recent input levels, newest last, for the waveform.
    var levels: [Float] = Array(repeating: 0, count: 24)

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// Floating, non-activating pill at the bottom center of the active screen.
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ state: HUDModel.State) {
        hideTask?.cancel()
        model.state = state
        if case .recording = state { model.levels = Array(repeating: 0, count: model.levels.count) }
        position()
        panel.orderFrontRegardless()
        if case .message = state {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        model.state = .hidden
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.black.opacity(0.82), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            Spacer(minLength: 0)
        }
        .frame(width: 320, height: 56)
        .foregroundStyle(.white)
        .font(.system(size: 13, weight: .medium))
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case let .recording(command):
            HStack(spacing: 10) {
                Image(systemName: command ? "wand.and.stars" : "mic.fill")
                    .foregroundStyle(command ? .purple : .red)
                Waveform(levels: model.levels)
            }
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Transcribing…")
            }
        case let .message(text, isError):
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isError ? .yellow : .white)
                Text(text).lineLimit(2).frame(maxWidth: 250)
            }
        }
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .frame(width: 3, height: 4 + CGFloat(min(levels[i] * 12, 1)) * 22)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
