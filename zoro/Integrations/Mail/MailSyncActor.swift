//
//  MailSyncActor.swift
//  zoro
//

import Foundation
import os

struct AccountFetchOutcome: Sendable {
    let accountId: UUID
    let result: MailFetchResult?
    let error: MailError?
}

struct AccountSyncOutcome: Sendable {
    let accountId: UUID
    let unread: MailFetchResult?
    let error: MailError?
}

/// Isolates mail network I/O from MainActor services. Provider implementations run here.
actor MailSyncActor {
    static let shared = MailSyncActor()

    static let maxConcurrentAccountSyncs = 3

    private let logger = Logger(subsystem: "com.zoro.mail", category: "MailSyncActor")

    private init() {}

    // MARK: - Single account

    func fetchUnread(from provider: any MailProvider, limit: Int) async throws -> MailFetchResult {
        try await provider.fetchUnread(limit: limit)
    }

    func search(from provider: any MailProvider, query: String, limit: Int) async throws -> MailFetchResult {
        try await provider.search(query: query, limit: limit)
    }

    func readMessage(from provider: any MailProvider, id: String) async throws -> MailMessageContent {
        try await provider.readMessage(id: id)
    }

    func archive(from provider: any MailProvider, id: String) async throws {
        try await provider.archive(id: id)
    }

    func markRead(from provider: any MailProvider, id: String) async throws {
        try await provider.markRead(id: id)
    }

    func createDraft(from provider: any MailProvider, draft: MailDraft) async throws -> String {
        try await provider.createDraft(draft)
    }

    func send(from provider: any MailProvider, draftId: String) async throws {
        try await provider.send(draftId: draftId)
    }

    // MARK: - Multi-account orchestration

    func fetchUnread(
        from providers: [any MailProvider],
        limitPerAccount: Int
    ) async -> [AccountFetchOutcome] {
        await runForProviders(providers) { provider in
            do {
                let result = try await provider.fetchUnread(limit: limitPerAccount)
                return AccountFetchOutcome(accountId: provider.accountId, result: result, error: nil)
            } catch let error as MailError {
                return AccountFetchOutcome(accountId: provider.accountId, result: nil, error: error)
            } catch {
                return AccountFetchOutcome(
                    accountId: provider.accountId,
                    result: nil,
                    error: .networkError(error.localizedDescription)
                )
            }
        }
    }

    func syncAccounts(
        providers: [any MailProvider],
        limitPerAccount: Int
    ) async -> [AccountSyncOutcome] {
        let outcomes = await fetchUnread(from: providers, limitPerAccount: limitPerAccount)
        return outcomes.map { outcome in
            AccountSyncOutcome(
                accountId: outcome.accountId,
                unread: outcome.result,
                error: outcome.error
            )
        }
    }

    func archiveBatch(
        items: [(provider: any MailProvider, messageId: String)]
    ) async -> [(accountId: UUID, messageId: String, error: MailError?)] {
        var results: [(accountId: UUID, messageId: String, error: MailError?)] = []

        for chunk in items.chunked(into: Self.maxConcurrentAccountSyncs) {
            await withTaskGroup(of: (UUID, String, MailError?).self) { group in
                for item in chunk {
                    group.addTask {
                        do {
                            try await item.provider.archive(id: item.messageId)
                            return (item.provider.accountId, item.messageId, nil)
                        } catch let error as MailError {
                            return (item.provider.accountId, item.messageId, error)
                        } catch {
                            return (
                                item.provider.accountId,
                                item.messageId,
                                .networkError(error.localizedDescription)
                            )
                        }
                    }
                }
                for await result in group {
                    results.append(result)
                }
            }
        }

        return results
    }

    // MARK: - Private

    private func runForProviders<T: Sendable>(
        _ providers: [any MailProvider],
        operation: @Sendable @escaping (any MailProvider) async -> T
    ) async -> [T] {
        guard !providers.isEmpty else { return [] }

        var outcomes: [T] = []

        for chunk in providers.chunked(into: Self.maxConcurrentAccountSyncs) {
            await withTaskGroup(of: T.self) { group in
                for provider in chunk {
                    group.addTask {
                        await operation(provider)
                    }
                }
                for await outcome in group {
                    outcomes.append(outcome)
                }
            }
        }

        return outcomes
    }
}

// MARK: - Chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
