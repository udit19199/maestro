//
//  EmailCalendarDetector.swift
//  zoro
//

import Foundation

/// Detects calendar events from email (.ics parse + heuristics) and produces Planner confirm proposals.
enum EmailCalendarDetector {
    struct ParsedEvent: Equatable, Sendable {
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let notes: String?
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - ICS parsing (pure)

    static func parseICS(_ content: String) -> [ParsedEvent] {
        let lines = unfoldICSLines(content)
        var events: [ParsedEvent] = []
        var inEvent = false
        var properties: [String: String] = [:]

        for line in lines {
            switch line {
            case "BEGIN:VEVENT":
                inEvent = true
                properties = [:]
            case "END:VEVENT":
                if inEvent, let event = eventFromProperties(properties) {
                    events.append(event)
                }
                inEvent = false
            default:
                if inEvent, let (key, value) = parseICSProperty(line) {
                    properties[key] = value
                }
            }
        }

        return events
    }

    static func proposalsFromHeuristics(
        subject: String,
        snippet: String,
        from: String
    ) -> [PlannerEventProposal] {
        guard CleanupHeuristics.isLikelyCalendarInvite(subject: subject, snippet: snippet) else {
            return []
        }

        let combined = "\(subject)\n\(snippet)"
        if let icsStart = combined.range(of: "BEGIN:VCALENDAR", options: .caseInsensitive) {
            let icsContent = String(combined[icsStart.lowerBound...])
            return parseICS(icsContent).map {
                toProposal($0, notes: "From: \(from)")
            }
        }

        let title = cleanedTitle(from: subject)
        guard let start = extractDate(from: combined) else { return [] }
        let end = start.addingTimeInterval(3600)

        return [
            PlannerEventProposal(
                title: title,
                startDate: isoFormatter.string(from: start),
                endDate: isoFormatter.string(from: end),
                notes: "Detected from email: \(from)"
            )
        ]
    }

    // MARK: - Async scan (reads full bodies for calendar candidates)

    static func scanForProposals(
        summaries: [MailMessageSummary],
        providers: [(provider: any MailProvider, account: MailAccount)],
        maxReads: Int = 3
    ) async -> [PlannerEventProposal] {
        var proposals: [PlannerEventProposal] = []
        var seen = Set<String>()

        let candidates = summaries.filter {
            $0.isUnread && CleanupHeuristics.isLikelyCalendarInvite(subject: $0.subject, snippet: $0.snippet)
        }

        for summary in candidates {
            for proposal in proposalsFromHeuristics(
                subject: summary.subject,
                snippet: summary.snippet,
                from: summary.from
            ) {
                let key = "\(proposal.title)|\(proposal.startDate)"
                if seen.insert(key).inserted {
                    proposals.append(proposal)
                }
            }
        }

        let providerMap = Dictionary(uniqueKeysWithValues: providers.map { ($0.account.id, $0.provider) })
        var reads = 0

        for summary in candidates {
            guard reads < maxReads else { break }

            let alreadyCovered = proposals.contains {
                $0.notes?.contains(summary.subject) == true || $0.title == cleanedTitle(from: summary.subject)
            }
            if alreadyCovered { continue }

            guard let provider = providerMap[summary.accountId] else { continue }

            do {
                let content = try await MailSyncActor.shared.readMessage(from: provider, id: summary.id)
                reads += 1

                if content.body.range(of: "BEGIN:VCALENDAR", options: .caseInsensitive) != nil {
                    for event in parseICS(content.body) {
                        let proposal = toProposal(
                            event,
                            notes: "From email: \(summary.from) — \(summary.subject)"
                        )
                        let key = "\(proposal.title)|\(proposal.startDate)"
                        if seen.insert(key).inserted {
                            proposals.append(proposal)
                        }
                    }
                } else {
                    for proposal in proposalsFromHeuristics(
                        subject: summary.subject,
                        snippet: content.body,
                        from: summary.from
                    ) {
                        let key = "\(proposal.title)|\(proposal.startDate)"
                        if seen.insert(key).inserted {
                            proposals.append(proposal)
                        }
                    }
                }
            } catch {
                continue
            }
        }

        return proposals
    }

    // MARK: - Helpers

    private static func toProposal(_ event: ParsedEvent, notes: String?) -> PlannerEventProposal {
        PlannerEventProposal(
            title: event.title,
            startDate: isoFormatter.string(from: event.startDate),
            endDate: isoFormatter.string(from: event.endDate),
            location: event.location,
            notes: event.notes ?? notes
        )
    }

    private static func eventFromProperties(_ properties: [String: String]) -> ParsedEvent? {
        guard let startRaw = properties["DTSTART"],
              let start = parseICSDate(startRaw) else {
            return nil
        }

        let end: Date
        if let endRaw = properties["DTEND"], let parsedEnd = parseICSDate(endRaw) {
            end = parsedEnd
        } else if let durationRaw = properties["DURATION"], let duration = parseICSDuration(durationRaw) {
            end = start.addingTimeInterval(duration)
        } else {
            end = start.addingTimeInterval(3600)
        }

        let title = properties["SUMMARY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }

        return ParsedEvent(
            title: title,
            startDate: start,
            endDate: end,
            location: properties["LOCATION"],
            notes: properties["DESCRIPTION"]
        )
    }

    private static func unfoldICSLines(_ content: String) -> [String] {
        var rawLines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var unfolded: [String] = []
        for line in rawLines {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line.dropFirst()
            } else {
                unfolded.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return unfolded.filter { !$0.isEmpty }
    }

    private static func parseICSProperty(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let keyPart = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        let key = keyPart.split(separator: ";", maxSplits: 1).first.map(String.init) ?? keyPart
        return (key.uppercased(), value)
    }

    private static func parseICSDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 8 {
            return parseCompactDate(value, includesTime: false)
        }
        if value.hasSuffix("Z") {
            return parseCompactDate(String(value.dropLast()), includesTime: true, timeZone: TimeZone(secondsFromGMT: 0))
        }
        return parseCompactDate(value, includesTime: value.contains("T"))
    }

    private static func parseCompactDate(
        _ value: String,
        includesTime: Bool,
        timeZone: TimeZone? = .current
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? .current

        if includesTime {
            guard value.count >= 15 else { return nil }
            let year = Int(value.prefix(4)) ?? 0
            let month = Int(value.dropFirst(4).prefix(2)) ?? 0
            let day = Int(value.dropFirst(6).prefix(2)) ?? 0
            let hour = Int(value.dropFirst(9).prefix(2)) ?? 0
            let minute = Int(value.dropFirst(11).prefix(2)) ?? 0
            let second = Int(value.dropFirst(13).prefix(2)) ?? 0
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            components.second = second
            return calendar.date(from: components)
        }

        guard value.count == 8 else { return nil }
        let year = Int(value.prefix(4)) ?? 0
        let month = Int(value.dropFirst(4).prefix(2)) ?? 0
        let day = Int(value.dropFirst(6).prefix(2)) ?? 0
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 9
        return calendar.date(from: components)
    }

    private static func parseICSDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix("P") else { return nil }

        var total: TimeInterval = 0
        var current = ""
        var inTime = false

        for character in trimmed.dropFirst() {
            if character == "T" {
                inTime = true
                continue
            }
            if character.isNumber || character == "." {
                current.append(character)
                continue
            }
            guard let value = Double(current) else { return nil }
            switch character {
            case "W": total += value * 7 * 24 * 3600
            case "D": total += value * 24 * 3600
            case "H": total += value * 3600
            case "M": total += inTime ? value * 60 : value * 30 * 24 * 3600
            case "S": total += value
            default: break
            }
            current = ""
        }

        return total > 0 ? total : nil
    }

    private static func cleanedTitle(from subject: String) -> String {
        var title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "invitation:",
            "invite:",
            "accepted:",
            "declined:",
            "updated invitation:",
            "canceled:",
            "cancelled:",
        ]
        for prefix in prefixes {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return title.isEmpty ? "Calendar event" : title
    }

    private static func extractDate(from text: String) -> Date? {
        let patterns: [String] = [
            #"(?i)\b(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s+[a-z]{3,9}\s+\d{1,2}(?:,?\s+\d{4})?(?:\s+(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?"#,
            #"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?"#,
            #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:,?\s+\d{4})?(?:\s+(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                let fragment = String(text[range])
                if let date = parseNaturalDate(fragment) {
                    return date
                }
            }
        }

        return nil
    }

    private static func parseNaturalDate(_ fragment: String) -> Date? {
        let formats = [
            "EEEE, MMMM d, yyyy 'at' h:mm a",
            "EEEE, MMMM d, yyyy",
            "MMMM d, yyyy 'at' h:mm a",
            "MMMM d, yyyy",
            "MMM d, yyyy 'at' h:mm a",
            "MMM d, yyyy",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: fragment.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return date
            }
        }

        return nil
    }
}
