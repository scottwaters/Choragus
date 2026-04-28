/// MarqueeText.swift — Auto-scrolling text that slides when content overflows.
///
/// Pauses at the start, slides to reveal the full text, pauses at the end,
/// then resets and repeats. Static when the text fits within the available width.
import SwiftUI
import SonosKit

struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var fontWeight: Font.Weight = .regular
    var foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    var pauseDuration: Double = 3.0
    var scrollSpeed: Double = 30.0 // points per second

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?

    private var needsScroll: Bool { textWidth > containerWidth && containerWidth > 0 }
    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .fontWeight(fontWeight)
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset)
                .onAppear {
                    containerWidth = geo.size.width
                    startAnimation()
                }
                .onChange(of: geo.size.width) {
                    containerWidth = geo.size.width
                    restartAnimation()
                }
                .onChange(of: text) {
                    restartAnimation()
                }
                .background {
                    Text(text)
                        .font(font)
                        .fontWeight(fontWeight)
                        .lineLimit(1)
                        .fixedSize()
                        .hidden()
                        .background(GeometryReader { textGeo in
                            Color.clear.onAppear {
                                textWidth = textGeo.size.width
                            }
                            .onChange(of: text) {
                                textWidth = textGeo.size.width
                            }
                        })
                }
        }
        .clipped()
        .frame(height: textHeight)
    }

    private var textHeight: CGFloat {
        // Approximate height based on font
        switch font {
        case .title: return 28
        case .title2: return 24
        case .title3: return 20
        case .body: return 17
        case .subheadline: return 15
        case .caption: return 13
        default: return 17
        }
    }

    private func startAnimation() {
        animationTask?.cancel()
        guard needsScroll else {
            offset = 0
            return
        }
        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                // Pause at start
                offset = 0
                try? await Task.sleep(nanoseconds: UInt64(pauseDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }

                // Slide to show overflow
                let duration = Double(overflow) / scrollSpeed
                withAnimation(.linear(duration: duration)) {
                    offset = -overflow
                }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }

                // Pause at end
                try? await Task.sleep(nanoseconds: UInt64(pauseDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }

                // Reset instantly
                withAnimation(.none) {
                    offset = 0
                }
                try? await Task.sleep(nanoseconds: Timing.marqueeAnimationPause)
            }
        }
    }

    private func restartAnimation() {
        animationTask?.cancel()
        offset = 0
        // Small delay to let geometry settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startAnimation()
        }
    }
}
