//
//  ProfileStore.swift
//  zoro
//

import Foundation
import Combine

enum MemoryFactSource: String, Codable, Sendable {
    case auto
    case manual
    case planner
    case teach
}

struct MemoryFact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var source: MemoryFactSource
    var createdAt: Date

    init(id: UUID = UUID(), text: String, source: MemoryFactSource, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
    }
}

struct UserProfile: Codable, Equatable, Sendable {
    var facts: [MemoryFact]
    var freeformNotes: String

    static let empty = UserProfile(facts: [], freeformNotes: "")
}

@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profile: UserProfile = .empty
    @Published var showMemoryUpdatedBanner = false

    private var saveTask: Task<Void, Never>?
    private let saveDebounceNanoseconds: UInt64 = 500_000_000

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = appSupport?.appendingPathComponent("Zoro", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Zoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var jsonURL: URL {
        storageDirectory.appendingPathComponent("profile.json")
    }

    private var markdownURL: URL {
        storageDirectory.appendingPathComponent("profile.md")
    }

    private init() {
        load()
    }

    func load() {
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            do {
                let data = try Data(contentsOf: jsonURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                profile = try decoder.decode(UserProfile.self, from: data)
                return
            } catch {
                // Fall through to markdown migration
            }
        }

        if FileManager.default.fileExists(atPath: markdownURL.path),
           let markdown = try? String(contentsOf: markdownURL, encoding: .utf8),
           !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile = UserProfile(facts: [], freeformNotes: markdown)
            scheduleSave()
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.persistNow()
        }
    }

    func persistNow() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profile)
            try data.write(to: jsonURL, options: .atomic)

            let markdown = profileMarkdownRepresentation()
            try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            // Silent failure; profile remains in memory
        }
    }

    func profileContextForPrompt() -> String {
        var sections: [String] = []
        if !profile.freeformNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Notes:\n\(profile.freeformNotes)")
        }
        if !profile.facts.isEmpty {
            let factLines = profile.facts.map { "- \($0.text)" }.joined(separator: "\n")
            sections.append("Known facts about the user:\n\(factLines)")
        }
        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n\n")
    }

    @discardableResult
    func addFact(_ text: String, source: MemoryFactSource, notify: Bool = true) -> MemoryFact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !profile.facts.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }

        let fact = MemoryFact(text: trimmed, source: source)
        profile.facts.append(fact)
        scheduleSave()
        if notify {
            showMemoryUpdatedBanner = true
        }
        return fact
    }

    func updateFact(id: UUID, text: String) {
        guard let index = profile.facts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profile.facts[index].text = trimmed
        scheduleSave()
    }

    func deleteFact(id: UUID) {
        profile.facts.removeAll { $0.id == id }
        scheduleSave()
    }

    func updateFreeformNotes(_ notes: String) {
        profile.freeformNotes = notes
        scheduleSave()
    }

    func dismissMemoryBanner() {
        showMemoryUpdatedBanner = false
    }

    private func profileMarkdownRepresentation() -> String {
        var lines = ["# Zoro Profile", ""]
        if !profile.freeformNotes.isEmpty {
            lines.append("## Notes")
            lines.append(profile.freeformNotes)
            lines.append("")
        }
        if !profile.facts.isEmpty {
            lines.append("## Facts")
            for fact in profile.facts {
                lines.append("- \(fact.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
