//
//  MailRowView.swift
//  zoro
//

import SwiftUI

struct MailRowView: View {
    let item: BriefingMailItem
    var onSelect: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(item.isUnread ? Color.accentColor : Color.clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.sender)
                            .font(.subheadline)
                            .fontWeight(item.isUnread ? .semibold : .regular)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(relativeTime(item.receivedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Text(item.subject)
                        .font(.subheadline)
                        .fontWeight(item.isUnread ? .medium : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                AccountBadge(label: item.accountLabel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Summarize this email in a new chat")
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    VStack(spacing: 12) {
        ForEach(BriefingMailItem.previewSamples) { item in
            MailRowView(item: item)
        }
    }
    .padding()
    .frame(width: 520)
}
