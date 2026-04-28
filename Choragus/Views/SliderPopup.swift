/// SliderPopup.swift — Shows a floating value label above a slider while dragging.
import SwiftUI

struct SliderWithPopup: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var step: Double? = nil
    var format: (Double) -> String = { "\(Int($0))" }
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var isDragging = false

    var body: some View {
        Slider(
            value: $value,
            in: range
        ) { editing in
            isDragging = editing
            onEditingChanged?(editing)
        }
        .overlay(alignment: .top) {
            if isDragging {
                Text(format(value))
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
}
