import AppKit
import SwiftUI

@Observable
final class HUDModel {
    enum State: Equatable {
        case hidden
        case recording(command: Bool)
        case processing(command: Bool)
        case done
        case message(String, isError: Bool)
    }

    var state: State = .hidden
    /// Recent input levels, newest last, for the waveform.
    var levels: [Float] = Array(repeating: 0, count: 12)
    var startedAt = Date()
    /// Recording continues without holding fn (double tap).
    var handsFree = false
    var notch = NotchGeometry.fallback

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// Size of the camera housing the island grows out of. Screens without a notch get a virtual one of width 0.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat

    static let fallback = NotchGeometry(width: 0, height: 32)

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
            self.init(width: screen.frame.width - left - right, height: screen.safeAreaInsets.top)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            self.init(width: 0, height: max(menuBar, 32))
        }
    }
}

/// Borderless panels are pushed below the menu bar by default; the island has to sit on top of it.
private final class IslandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A Dynamic Island grown out of the MacBook notch: idle it's invisible inside the camera housing,
/// then it springs out sideways while listening and folds back in when done.
final class HUDController {
    let model = HUDModel()
    private let panel: IslandPanel
    private var hideTask: Task<Void, Never>?
    private static let panelSize = NSSize(width: 720, height: 200)

    init() {
        panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
    }

    func show(_ state: HUDModel.State) {
        hideTask?.cancel()
        if case .recording = state {
            model.levels = Array(repeating: 0, count: model.levels.count)
            model.startedAt = .now
            model.handsFree = false
        }
        if panel.isVisible {
            model.state = state
        } else {
            // Start folded inside the notch so the first frame is invisible, then grow out of it.
            model.state = .hidden
            place()
            panel.orderFrontRegardless()
            DispatchQueue.main.async { self.model.state = state }
        }
        switch state {
        case .done: hide(after: 0.9)
        case .message: hide(after: 2.8)
        default: break
        }
    }

    func hide() { hide(after: 0) }

    private func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            model.state = .hidden
            // Let the island fold back into the notch before removing the window.
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, model.state == .hidden else { return }
            panel.orderOut(nil)
        }
    }

    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        model.notch = NotchGeometry(screen: screen)
        let size = Self.panelSize
        panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height),
            display: false
        )
    }
}

// MARK: - Island

private enum Island {
    static let wing: CGFloat = 86
    static let inset: CGFloat = 16
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let brand = [Color(red: 0.25, green: 0.48, blue: 1.0), Color(red: 0.55, green: 0.33, blue: 1.0), Color(red: 1.0, green: 0.36, blue: 0.62)]
    static let command = [Color(red: 0.62, green: 0.38, blue: 1.0), Color(red: 0.86, green: 0.42, blue: 1.0)]
}

struct IslandView: View {
    let model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var notch: NotchGeometry { model.notch }
    private var isOpen: Bool { model.state != .hidden }
    private var message: (text: String, isError: Bool)? {
        if case let .message(text, isError) = model.state { return (text, isError) }
        return nil
    }

    private var bodyWidth: CGFloat {
        guard isOpen else { return notch.width }
        let compact = notch.width + Island.wing * 2
        return message == nil ? compact : max(compact, 400)
    }

    private var bodyHeight: CGFloat {
        guard isOpen else { return notch.height }
        return message == nil ? notch.height : notch.height + 40
    }

    private var topRadius: CGFloat { isOpen ? 8 : 4 }
    private var bottomRadius: CGFloat { isOpen ? (message == nil ? 14 : 22) : 8 }

    var body: some View {
        ZStack(alignment: .top) {
            glow
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(.black)
                .frame(width: bodyWidth + topRadius * 2, height: bodyHeight)
                .overlay(alignment: .top) { content.padding(.horizontal, topRadius) }
                .shadow(color: .black.opacity(isOpen ? 0.35 : 0), radius: 12, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Island.spring, value: model.state)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Island.spring, value: model.handsFree)
    }

    // Wings sit left and right of the camera; nothing is drawn where the notch hides it.
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.padding(.leading, Island.inset).frame(width: Island.wing, alignment: .leading)
                Spacer(minLength: notch.width)
                trailing.padding(.trailing, Island.inset).frame(width: Island.wing, alignment: .trailing)
            }
            .frame(width: bodyWidth, height: notch.height)
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "waveform.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(message.isError ? .yellow : .white.opacity(0.6))
                    Text(message.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 22)
                .frame(width: bodyWidth, height: 38)
                .transition(.blurReplace)
            }
        }
        .opacity(isOpen ? 1 : 0)
        .blur(radius: isOpen ? 0 : 6)
        .frame(width: bodyWidth, height: bodyHeight, alignment: .top)
        .clipped()
    }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .hidden:
            Color.clear
        case let .recording(command):
            HStack(spacing: 7) {
                if command {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: Island.command, startPoint: .leading, endPoint: .trailing))
                } else {
                    RecordingDot()
                }
                if model.handsFree {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Elapsed(since: model.startedAt)
            }
            .transition(.blurReplace)
        case .processing:
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: Island.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.pulse, options: .repeating)
                .transition(.blurReplace)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white, .green)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .message:
            Color.clear
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.state {
        case let .recording(command):
            Bars(levels: model.levels, colors: command ? Island.command : Island.brand, thinking: false)
                .transition(.blurReplace)
        case let .processing(command):
            Bars(levels: model.levels, colors: command ? Island.command : Island.brand, thinking: true)
                .transition(.blurReplace)
        case .done:
            Text("Pasted")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .transition(.blurReplace)
        case .hidden, .message:
            Color.clear
        }
    }

    /// Soft brand-colored light under the island that breathes with the voice.
    private var glow: some View {
        let level = CGFloat(min((model.levels.suffix(4).reduce(0, +) / 4) * 14, 1))
        let visible: Bool = switch model.state {
        case .recording, .processing: true
        default: false
        }
        return Capsule()
            .fill(LinearGradient(colors: Island.brand, startPoint: .leading, endPoint: .trailing))
            .frame(width: bodyWidth * 0.7, height: 18)
            .blur(radius: 18)
            .opacity(visible ? 0.25 + level * 0.55 : 0)
            .offset(y: bodyHeight - 12)
            .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy(duration: 0.25), value: seconds)
        }
    }
}

private struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.27, blue: 0.27))
            .frame(width: 7, height: 7)
            .background(Circle().fill(.red.opacity(0.45)).scaleEffect(pulse ? 2.4 : 1).opacity(pulse ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// Live level bars while listening; the same bars turn into a travelling wave while transcribing,
/// so the island morphs instead of swapping widgets.
private struct Bars: View {
    let levels: [Float]
    let colors: [Color]
    let thinking: Bool

    var body: some View {
        TimelineView(.animation(paused: !thinking)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule().frame(width: 3, height: height(i, t))
                }
            }
            .frame(height: 20)
            .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.7), value: levels)
        }
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        if thinking {
            return 4 + 9 * CGFloat((sin(t * 7 - Double(i) * 0.55) + 1) / 2)
        }
        // Louder in the middle, quieter at the edges, like a voice memo.
        let center = Double(levels.count - 1) / 2
        let weight = 1 - abs(Double(i) - center) / (center + 1) * 0.55
        let level = min(sqrt(Double(levels[i])) * 3.4, 1) * weight
        return 3 + 17 * CGFloat(level)
    }
}

/// Notch silhouette: the top corners flare outward into the menu bar like the real camera housing.
nonisolated struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height - topRadius, (rect.width - topRadius * 2) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
                       control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topRadius + bottom, y: rect.maxY),
                       control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottom, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottom),
                       control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
