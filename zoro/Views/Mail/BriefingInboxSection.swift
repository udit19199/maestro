//
//  BriefingInboxSection.swift
//  zoro
//

import SwiftUI

struct BriefingInboxSection: View {
    let digest: String
    let items: [BriefingMailItem]
    let unreadTotal: Int
    let pendingCleanupCount: Int
    let state: BriefingInboxState
    var onSelectItem: ((BriefingMailItem) -> Void)?
    var onReviewCleanup: (() -> Void)?
    var onConnectAccounts: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Inbox")
                    .font(.headline)
                Spacer()
                if unreadTotal > 0 {
                    Text("\(unreadTotal) unread")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Syncing inboxes…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)

        case .noAccounts:
            connectAccountsPrompt

        case .empty(let message):
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .error(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.body)
            .foregroundStyle(.secondary)

        case .loaded:
            if !digest.isEmpty {
                Text(digest)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if items.isEmpty {
                Text("No priority unread messages right now.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        MailRowView(item: item) {
                            onSelectItem?(item)
                        }
                    }
                }
            }

            if pendingCleanupCount > 0 {
                Button {
                    onReviewCleanup?()
                } label: {
                    Label("Review \(pendingCleanupCount) newsletters", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
    }

    private var connectAccountsPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("No email accounts connected")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Connect Gmail or an IMAP account to see priority unread, digests, and cleanup here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                onConnectAccounts?()
            } label: {
                Label("Connect email account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Loaded") {
    BriefingInboxSection(
        digest: "2 need reply · 5 newsletters · 1 invite",
        items: BriefingMailItem.previewSamples,
        unreadTotal: 12,
        pendingCleanupCount: 23,
        state: .loaded
    )
    .padding()
    .frame(width: 720)
}

#Preview("No accounts") {
    BriefingInboxSection(
        digest: "",
        items: [],
        unreadTotal: 0,
        pendingCleanupCount: 0,
        state: .noAccounts,
        onConnectAccounts: {}
    )
    .padding()
    .frame(width: 720)
}

#Preview("Empty") {
    BriefingInboxSection(
        digest: "",
        items: [],
        unreadTotal: 0,
        pendingCleanupCount: 0,
        state: .empty(message: "No unread mail across your connected accounts.")
    )
    .padding()
    .frame(width: 720)
}
