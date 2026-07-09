//
//  CleanupReviewSheet.swift
//  zoro
//

import SwiftUI

struct CleanupReviewItem: Identifiable, Equatable, Sendable {
    let id: String
    let accountId: UUID
    let accountLabel: String
    let sender: String
    let subject: String
    let receivedAt: Date
}

struct CleanupReviewSheet: View {
    let items: [CleanupReviewItem]
    let isArchiving: Bool
    var onArchiveAll: () -> Void
    var onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Archive newsletters?")
                        .font(.headline)
                    Text("\(items.count) messages look like newsletters or promotions. They will be archived, not deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            List(items) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.sender)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(item.subject)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    AccountBadge(label: item.accountLabel)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .frame(minHeight: 200, maxHeight: 320)

            HStack {
                Button("Skip") {
                    onSkip()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isArchiving ? "Archiving…" : "Archive all") {
                    onArchiveAll()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isArchiving || items.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 420)
    }
}

extension CleanupReviewItem {
    static let previewSamples: [CleanupReviewItem] = [
        CleanupReviewItem(
            id: "c1",
            accountId: UUID(),
            accountLabel: "personal@gmail",
            sender: "Medium Daily Digest",
            subject: "Stories for you",
            receivedAt: Date().addingTimeInterval(-86400)
        ),
        CleanupReviewItem(
            id: "c2",
            accountId: UUID(),
            accountLabel: "work@gmail",
            sender: "Vercel",
            subject: "Product Update",
            receivedAt: Date().addingTimeInterval(-172800)
        )
    ]
}

#Preview {
    CleanupReviewSheet(
        items: CleanupReviewItem.previewSamples,
        isArchiving: false,
        onArchiveAll: {},
        onSkip: {}
    )
}
