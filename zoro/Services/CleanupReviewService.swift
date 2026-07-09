//
//  CleanupReviewService.swift
//  zoro
//

import Foundation
import Combine
import os

/// Weekly cleanup orchestration: scan newsletter candidates and archive in batch after user review.
@MainActor
final class CleanupReviewService: ObservableObject {
    static let shared = CleanupReviewService()

    @Published private(set) var pendingItems: [CleanupReviewItem] = []
    @Published private(set) var isArchiving = false
    @Published private(set) var lastScanAt: Date?

    private var weeklyTimer: Timer?
    private let logger = Logger(subsystem: "com.zoro.mail", category: "CleanupReviewService")

    private init() {}

    // MARK: - Weekly schedule (Sunday 6 PM local)

    func startWeeklySchedule() {
        scheduleNextWeeklyScan()
    }

    func stopWeeklySchedule() {
        weeklyTimer?.invalidate()
        weeklyTimer = nil
    }

    private func scheduleNextWeeklyScan() {
        weeklyTimer?.invalidate()
        guard let nextRun = Self.nextSundayAtHour(18) else { return }
        let interval = max(1, nextRun.timeIntervalSinceNow)
        logger.info("Next weekly cleanup scan scheduled in \(interval, privacy: .public)s")
        weeklyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.runWeeklyScan()
                self?.scheduleNextWeeklyScan()
            }
        }
    }

    private func runWeeklyScan() async {
        logger.info("Running scheduled weekly cleanup scan")
        await scanCandidates()
        BriefingService.shared.syncPendingCleanupCount(pendingItems.count)
    }

    static func nextSundayAtHour(_ hour: Int, from now: Date = Date()) -> Date? {
        var calendar = Calendar.current
        calendar.timeZone = .current

        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = 1 // Sunday
        components.hour = hour
        components.minute = 0
        components.second = 0

        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate <= now {
            candidate = calendar.date(byAdding: .weekOfYear, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    // MARK: - Scan

    func scanCandidates() async {
        let mail = MailManager.shared
        guard !mail.configuredAccounts().isEmpty else {
            pendingItems = []
            lastScanAt = Date()
            return
        }

        if mail.allUnreadSummaries.isEmpty || mail.lastSyncedAt == nil {
            await mail.syncAllAccounts(limitPerAccount: 100)
        }

        let labels = MailAccountStore.shared.accountLabelsByID()
        pendingItems = mail.allUnreadSummaries
            .filter { CleanupHeuristics.isCleanupCandidate($0) }
            .sorted { $0.receivedAt > $1.receivedAt }
            .map { summary in
                CleanupReviewItem(
                    id: summary.id,
                    accountId: summary.accountId,
                    accountLabel: labels[summary.accountId] ?? "mail",
                    sender: Self.displaySender(summary.from),
                    subject: summary.subject,
                    receivedAt: summary.receivedAt
                )
            }

        lastScanAt = Date()
        BriefingService.shared.syncPendingCleanupCount(pendingItems.count)
    }

    // MARK: - Archive batch

    @discardableResult
    func archiveAll() async -> String {
        guard !pendingItems.isEmpty else {
            return "No cleanup candidates to archive."
        }

        isArchiving = true
        defer { isArchiving = false }

        let mail = MailManager.shared
        var batch: [(provider: any MailProvider, messageId: String)] = []

        for item in pendingItems {
            guard let account = MailAccountStore.shared.account(id: item.accountId),
                  let provider = mail.makeProvider(for: account) else {
                continue
            }
            batch.append((provider, item.id))
        }

        guard !batch.isEmpty else {
            return "Error: Could not resolve mail providers for cleanup candidates."
        }

        let results = await MailSyncActor.shared.archiveBatch(items: batch)
        let archived = results.filter { $0.error == nil }.count
        let failed = results.count - archived

        pendingItems = []
        await mail.syncAllAccounts(limitPerAccount: 100)
        BriefingService.shared.syncPendingCleanupCount(mail.pendingCleanupCount)
        lastScanAt = Date()

        if failed == 0 {
            return "Archived \(archived) message\(archived == 1 ? "" : "s")."
        }
        return "Archived \(archived) message\(archived == 1 ? "" : "s"); \(failed) failed."
    }

    private static func displaySender(_ from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        if let angleStart = trimmed.firstIndex(of: "<") {
            let name = trimmed[..<angleStart].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        if let atIndex = trimmed.firstIndex(of: "@") {
            return String(trimmed[..<atIndex])
        }
        return trimmed
    }
}
