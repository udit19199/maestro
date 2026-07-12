//
//  SecurityPolicyTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class SecurityPolicyTests: XCTestCase {

    // MARK: - Tool matrix

    func testShellDeniedOnIMessage() {
        let ctx = AgentExecutionContext.iMessage(requester: "+15551212")
        XCTAssertFalse(SecurityPolicy.isToolPermitted("run_terminal_command", context: ctx))
        XCTAssertFalse(SecurityPolicy.isToolPermitted("write_file", context: ctx))
        XCTAssertFalse(SecurityPolicy.isToolPermitted("send_imessage", context: ctx))
        XCTAssertFalse(SecurityPolicy.isToolPermitted("update_user_memory", context: ctx))
        XCTAssertNotNil(SecurityPolicy.toolPermissionError(for: "run_terminal_command", context: ctx))
    }

    func testRemoteAllowsReadOnlyMailAndFiles() {
        let ctx = AgentExecutionContext.iMessage(requester: "+15551212")
        XCTAssertTrue(SecurityPolicy.isToolPermitted("read_file", context: ctx))
        XCTAssertTrue(SecurityPolicy.isToolPermitted("manage_mail", context: ctx))
        XCTAssertTrue(SecurityPolicy.isMailActionPermitted("read_message", context: ctx))
        XCTAssertFalse(SecurityPolicy.isMailActionPermitted("send_email", context: ctx))
        XCTAssertFalse(SecurityPolicy.isCalendarActionPermitted("create_event", context: ctx))
    }

    func testLocalAllowsShell() {
        XCTAssertTrue(SecurityPolicy.isToolPermitted("run_terminal_command", context: .local))
        XCTAssertTrue(SecurityPolicy.isToolPermitted("send_imessage", context: .local))
    }

    func testEffectiveRecipientForcedOnRemote() {
        let ctx = AgentExecutionContext.iMessage(requester: "+1555")
        XCTAssertEqual(
            SecurityPolicy.effectiveIMessageRecipient(requested: "other@example.com", context: ctx),
            "+1555"
        )
        XCTAssertEqual(
            SecurityPolicy.effectiveIMessageRecipient(requested: "x", context: .local),
            "x"
        )
    }

    func testRecipientPermitted() {
        let ctx = AgentExecutionContext.iMessage(requester: "+1 (555) 1212")
        XCTAssertTrue(SecurityPolicy.isIMessageRecipientPermitted("15551212", context: ctx))
        XCTAssertFalse(SecurityPolicy.isIMessageRecipientPermitted("999", context: ctx))
        XCTAssertTrue(SecurityPolicy.isIMessageRecipientPermitted("anyone", context: .local))
    }

    func testWhitelistNormalization() {
        XCTAssertTrue(SecurityPolicy.isSenderWhitelisted(
            "+1 415-555-1212",
            whitelist: "4155551212, other@example.com"
        ))
        XCTAssertFalse(SecurityPolicy.isSenderWhitelisted("999", whitelist: "4155551212"))
        XCTAssertFalse(SecurityPolicy.isSenderWhitelisted("4155551212", whitelist: ""))
        XCTAssertFalse(SecurityPolicy.isSenderWhitelisted("", whitelist: "4155551212"))
        XCTAssertFalse(SecurityPolicy.hasNonEmptyWhitelist(" , , "))
        XCTAssertTrue(SecurityPolicy.hasNonEmptyWhitelist("a@b.com"))
    }

    // MARK: - Paths

    func testRejectsAbsolutePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        if case .failure = SecurityPolicy.resolveWorkspacePath("/etc/passwd", relativeTo: root) {
            // ok
        } else {
            XCTFail("Absolute path should fail")
        }
        if case .failure = SecurityPolicy.resolveWorkspacePath("~/Secret", relativeTo: root) {
            // ok
        } else {
            XCTFail("~ path should fail")
        }
    }

    func testAllowsRelativeInsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        switch SecurityPolicy.resolveWorkspacePath("note.txt", relativeTo: root) {
        case .success(let url):
            XCTAssertEqual(url.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        case .failure(let err):
            XCTFail(err.message)
        }
    }

    func testSymlinkEscapeRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let secret = outside.appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)

        let link = root.appendingPathComponent("evil_link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        switch SecurityPolicy.resolveWorkspacePath("evil_link/secret.txt", relativeTo: root) {
        case .success:
            XCTFail("Symlink escape should be rejected")
        case .failure:
            break
        }
    }

    // MARK: - Conversation context

    func testConversationExecutionContext() {
        let local = Conversation.new(agentType: .default, source: .desktop)
        XCTAssertEqual(try? local.executionContext().get(), .local)

        let remoteOk = Conversation.new(
            agentType: .default,
            source: .imessage,
            remoteRequester: "+1555"
        )
        XCTAssertEqual(try? remoteOk.executionContext().get(), .iMessage(requester: "+1555"))

        let remoteBad = Conversation.new(agentType: .default, source: .imessage, remoteRequester: nil)
        if case .failure(.missingRemoteRequester) = remoteBad.executionContext() {
            // ok
        } else {
            XCTFail("Missing requester should fail closed")
        }
    }

    func testToolFactoryNamesMatchDefaultAgent() {
        let names = ToolFactory.toolNames(for: .default)
        XCTAssertTrue(names.contains("manage_mail"))
        XCTAssertTrue(names.contains("send_imessage"))
        XCTAssertTrue(names.contains("run_terminal_command"))
    }
}

private extension Result where Failure: Error {
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
