/// SliderPopup.swift — Shows a floating value label above a slider while dragging,
/// and a popover that lets the user type an exact volume number.
import SwiftUI
import AppKit
import SonosKit

/// Custom horizontal alignment used to lock the master volume slider's
/// centre to each per-speaker slider's centre, regardless of the leading
/// (mute icon + speaker name) and trailing (numeric value) widths each
/// row contributes. Apply via `.alignmentGuide(.sliderCenter) { d in
/// d[HorizontalAlignment.center] }` on every slider that should share
/// the column, and host the rows inside a `VStack(alignment: .sliderCenter)`.
extension HorizontalAlignment {
    private enum SliderCenterID: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[HorizontalAlignment.center]
        }
    }
    static let sliderCenter = HorizontalAlignment(SliderCenterID.self)
}

/// Popover triggered by double-clicking a volume number label. Opens with the
/// current value pre-populated and pre-selected, so the user can immediately
/// type to replace. Return commits, Escape cancels.
struct VolumeNumberInputPopover: View {
    let initialValue: Int
    let onCommit: (Int) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool
    @State private var didSelectAll = false

    init(initialValue: Int,
         onCommit: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void) {
        let clamped = max(0, min(100, initialValue))
        self.initialValue = clamped
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: "\(clamped)")
    }

    private var parsedValue: Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let v = Int(trimmed) else { return nil }
        return (0...100).contains(v) ? v : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .frame(width: 64)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, newValue in
                        text = sanitize(newValue)
                    }
                Text("0–100")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(L10n.cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.setValue) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedValue == nil)
            }
        }
        .padding(12)
        .onAppear {
            focused = true
            // selectAll has to run after the field has attached to a window
            // and become first responder. A short defer is the standard
            // workaround for AppKit-hosted SwiftUI text fields.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if !didSelectAll {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    didSelectAll = true
                }
            }
        }
    }

    private func commit() {
        if let v = parsedValue {
            onCommit(v)
        } else {
            onCancel()
        }
    }

    /// Strips non-digit characters and clamps the numeric value to 0...100.
    /// Empty string is allowed mid-edit (user has backspaced everything).
    /// Leading zeros are allowed but the value stays clamped.
    private func sanitize(_ raw: String) -> String {
        let digits = raw.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        // Cap at 3 digits and clamp numeric value.
        let trimmed = String(digits.prefix(3))
        if let v = Int(trimmed), v > 100 { return "100" }
        return trimmed
    }
}

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
