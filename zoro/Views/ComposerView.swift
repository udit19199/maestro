//
//  ComposerView.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import SwiftUI

enum ComposerStyle {
    case slim
    case full
}

struct ComposerView: View {
    let style: ComposerStyle
    let placeholder: String
    let isRunning: Bool
    let isDisabled: Bool
    @Binding var text: String
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if style == .full {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 44, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .onSubmit(onSend)
            }

            Button(action: onSend) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isDisabled || (isRunning && !canSendWhileRunning) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var canSendWhileRunning: Bool {
        WorkspaceManager.shared.clarifyContinuation != nil
    }
}
