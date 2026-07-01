//
//  StoredMessage.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import Foundation

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct StoredMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String

    init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
