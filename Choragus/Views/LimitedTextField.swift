/// LimitedTextField.swift — A text field with a hard character cap.
///
/// The binding rejects any value past `limit`, so the field never shows
/// more than the cap and a keystroke at the limit is a no-op; the counter
/// beside it says why. Used wherever a string ends up in a menu label or
/// a bounded request (service names, the AI brief, playlist names).
import SwiftUI

/// Multi-line variant for briefs: three lines tall by default, grows
/// with the text, same hard cap and counter as `LimitedTextField`.
struct LimitedTextEditor: View {
    let placeholder: String
    @Binding var text: String
    let limit: Int
    var minLines: Int = 3

    private var capped: Binding<String> {
        Binding(get: { text }, set: { text = String($0.prefix(limit)) })
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: capped)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .frame(minHeight: CGFloat(minLines) * 20 + 12)
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            Text("\(text.count)/\(limit)")
                .font(.caption)
                .foregroundStyle(text.count >= limit ? .orange : .secondary)
                .monospacedDigit()
        }
    }
}

struct LimitedTextField: View {
    let placeholder: String
    @Binding var text: String
    let limit: Int
    var secure = false

    private var capped: Binding<String> {
        Binding(
            get: { text },
            set: { value in
                // Written even when unchanged: a keystroke at the cap
                // yields the same capped value, and only a state write
                // makes SwiftUI push it back into the NSTextField.
                text = String(value.prefix(limit))
            })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: capped)
                .textFieldStyle(.roundedBorder)
            Text("\(text.count)/\(limit)")
                .font(.caption)
                .foregroundStyle(text.count >= limit ? .orange : .secondary)
                .monospacedDigit()
        }
    }
}
