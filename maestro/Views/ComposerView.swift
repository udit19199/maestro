import SwiftUI

struct ComposerView: View {
    let placeholder: String
    let isRunning: Bool
    let isDisabled: Bool
    @Binding var text: String
    let onSend: () -> Void

    private var canSend: Bool {
        !isDisabled && !isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...5)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .accessibilityLabel(placeholder)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if canSend { onSend() }
                    return .handled
                }
            Button(action: onSend) {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send message")
            .disabled(!canSend)
        }
        .padding(14)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.25)))
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
    }
}
