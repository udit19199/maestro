//
//  AccountBadge.swift
//  zoro
//

import SwiftUI

struct AccountBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }
}

#Preview {
    HStack {
        AccountBadge(label: "work@gmail")
        AccountBadge(label: "icloud")
    }
    .padding()
}
