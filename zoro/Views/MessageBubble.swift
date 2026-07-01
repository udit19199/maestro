//
//  MessageBubble.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct MessageBubble: View {
    let message: StoredMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 600, alignment: .trailing)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.35, green: 0.34, blue: 0.84))
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Zoro")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fontWeight(.semibold)

                        Text(message.content)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(NSColor.controlBackgroundColor))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                Spacer()
            }
        }
    }
}
