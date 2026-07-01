//
//  TeachProgressTool.swift
//  zoro
//

import Foundation
import FoundationModels

@MainActor
struct TeachProgressTool: Tool {
    let name = "update_tutoring_progress"
    let description = "Update tutoring curriculum state for the current Teach conversation. Use after each lesson segment to track topic, module progress, and next steps."

    @Generable
    struct Arguments {
        @Guide(description: "Main curriculum topic being taught")
        var curriculumTopic: String?

        @Guide(description: "Summary of the most recent lesson segment")
        var lastLessonSummary: String?

        @Guide(description: "Current module or lesson name")
        var currentModule: String?

        @Guide(description: "Modules the learner has completed")
        var completedModules: [String]?

        @Guide(description: "Next exercise or concept to cover")
        var nextExercise: String?

        @Guide(description: "Recent understanding check questions or results")
        var understandingChecks: [String]?
    }

    func call(arguments: Arguments) async throws -> String {
        guard let conversationID = await WorkspaceManager.shared.activeConversationID else {
            return "Error: no active conversation."
        }

        await ConversationStore.shared.updateTutoringMetadata(conversationID: conversationID) { metadata in
            if let topic = arguments.curriculumTopic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
                metadata.curriculumTopic = topic
            }
            if let summary = arguments.lastLessonSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                metadata.lastLessonSummary = summary
            }
            if let module = arguments.currentModule?.trimmingCharacters(in: .whitespacesAndNewlines), !module.isEmpty {
                metadata.currentModule = module
            }
            if let completed = arguments.completedModules, !completed.isEmpty {
                var existing = metadata.completedModules ?? []
                for module in completed where !existing.contains(module) {
                    existing.append(module)
                }
                metadata.completedModules = existing
            }
            if let next = arguments.nextExercise?.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty {
                metadata.nextExercise = next
            }
            if let checks = arguments.understandingChecks, !checks.isEmpty {
                var existing = metadata.understandingChecks ?? []
                existing.append(contentsOf: checks)
                metadata.understandingChecks = Array(existing.suffix(10))
            }
        }

        if let topic = arguments.curriculumTopic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty {
            _ = await ProfileStore.shared.addFact("Learning: \(topic)", source: .teach, notify: false)
        }
        if let summary = arguments.lastLessonSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            _ = await ProfileStore.shared.addFact("Tutoring progress: \(summary)", source: .teach, notify: false)
        }

        return "Tutoring progress updated."
    }
}
