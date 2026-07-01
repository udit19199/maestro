//
//  AgentType.swift
//  zoro
//
//  Created by Udit Agarwal on 01/07/26.
//

import Foundation

enum AgentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case `default`
    case research
    case planner
    case teach

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "General"
        case .research: return "Research"
        case .planner: return "Planner"
        case .teach: return "Teach"
        }
    }

    var systemImage: String {
        switch self {
        case .default: return "sparkles"
        case .research: return "magnifyingglass"
        case .planner: return "calendar"
        case .teach: return "book.fill"
        }
    }

    var greeting: String {
        switch self {
        case .default:
            return "Hello! I'm Zoro, your personal assistant. Ask me anything."
        case .research:
            return "Research mode ready. I can search the web and compile findings into Apple Notes."
        case .planner:
            return "Planner mode ready. I can help with your calendar, reminders, and daily planning."
        case .teach:
            return "Teach mode ready. Tell me what you'd like to learn and we'll build a curriculum together."
        }
    }
}
