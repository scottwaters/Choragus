/// HoverTooltip.swift — Reliable tooltip that appears on hover after a short delay.
/// Replaces SwiftUI's .help() which is unreliable on macOS.
import SwiftUI

struct HoverTooltip: ViewModifier {
    let text: String
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s delay
                        guard !Task.isCancelled, isHovering else { return }
                        withAnimation(.easeIn(duration: 0.15)) {
                            showTooltip = true
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        showTooltip = false
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if showTooltip {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .fixedSize()
                        .offset(y: 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        modifier(HoverTooltip(text: text))
    }
}
