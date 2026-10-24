//
//  MessageBubble.swift
//  maestro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

struct MessageBubble: View {
  let message: StoredMessage
  @ObservedObject private var bots = BotLibrary.shared

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
            Text(message.botID.flatMap { bots.bot(id: $0)?.name } ?? "Maestro")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fontWeight(.semibold)

            Text(
              message.content.isEmpty && message.status == .streaming
                ? "Working..." : message.content
            )
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
            if message.status == .failed {
              Text(message.failure ?? "This request failed.").font(.caption).foregroundStyle(.red)
            } else if message.status == .stopped || message.status == .interrupted {
              Text(
                message.status == .stopped
                  ? "Stopped. This reply is incomplete." : "Interrupted. This reply is incomplete."
              )
              .font(.caption).foregroundStyle(.secondary)
            } else if message.status == .completed && message.content.isEmpty {
              Text("No response returned.").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxWidth: 700, alignment: .leading)
        Spacer()
      }
    }
  }
}
