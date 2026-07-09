//
//  MailSendConfirmPanel.swift
//  zoro
//

import SwiftUI

struct PendingMailSend: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountLabel: String
    let to: String
    let subject: String
    let bodyPreview: String
}

struct MailSendConfirmPanel: View {
    let pending: PendingMailSend
    let isSending: Bool
    var onSend: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send this email?")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                headerField("From", value: pending.accountLabel)
                headerField("To", value: pending.to)
                headerField("Subject", value: pending.subject)
                Text(pending.bodyPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button(isSending ? "Sending…" : "Send") {
                    onSend()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSending)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    private func headerField(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}

extension PendingMailSend {
    static let previewSample = PendingMailSend(
        id: UUID(),
        accountLabel: "work@gmail",
        to: "john@example.com",
        subject: "Re: Contract review",
        bodyPreview: "Thanks for sending this over. I reviewed section 4 and have a few notes…"
    )
}

#Preview {
    MailSendConfirmPanel(
        pending: .previewSample,
        isSending: false,
        onSend: {},
        onCancel: {}
    )
    .frame(width: 600)
}
