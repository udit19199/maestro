//
//  CodexRequestSupportTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class CodexRequestSupportTests: XCTestCase {
    func testStripReasoningItemsRemovesReasoningOnly() {
        let items: [CodexJSONValue] = [
            .object(["type": .string("message"), "role": .string("user")]),
            .object(["type": .string("reasoning"), "id": .string("rs_1")]),
            .object(["type": .string("function_call"), "call_id": .string("call_1")])
        ]

        let filtered = CodexRequestSupport.stripReasoningItems(items)
        XCTAssertEqual(filtered.count, 2)
        if case .object(let dict) = filtered[0] {
            XCTAssertEqual(dict["type"]?.stringValue, "message")
        } else {
            XCTFail("Expected first item to remain a message")
        }
    }

    func testBuildRequestPayloadSetsRequiredCodexFields() {
        let payload = CodexRequestSupport.buildRequestPayload(
            modelName: "gpt-5-codex",
            instructions: "You are Zoro.",
            inputItems: [
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string("hi")])
                    ])
                ])
            ],
            tools: [],
            temperature: nil
        )

        XCTAssertEqual(payload["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(payload["stream"], .bool(true))
        XCTAssertEqual(payload["store"], .bool(false))
        XCTAssertEqual(payload["instructions"]?.stringValue, "You are Zoro.")
    }

    func testStreamParserHandlesTextDelta() throws {
        var parser = CodexStreamParser()
        let actions = try parser.consume(eventJSON: #"{"type":"response.output_text.delta","delta":"Hello"}"#)
        XCTAssertEqual(actions, [.appendText("Hello")])
    }

    func testStreamParserHandlesFunctionCallLifecycle() throws {
        var parser = CodexStreamParser()

        let added = try parser.consume(eventJSON: """
        {"type":"response.output_item.added","item":{"type":"function_call","call_id":"call_1","name":"read_file","arguments":""}}
        """)
        XCTAssertEqual(added, [.startToolCall(id: "call_1", name: "read_file")])

        let delta = try parser.consume(eventJSON: """
        {"type":"response.function_call_arguments.delta","item_id":"call_1","delta":"{\\"path\\":"}
        """)
        XCTAssertEqual(delta, [.appendToolArguments(id: "call_1", delta: "{\"path\":")])

        let done = try parser.consume(eventJSON: """
        {"type":"response.function_call_arguments.done","item_id":"call_1","name":"read_file","arguments":"{\\"path\\":\\"README.md\\"}"}
        """)
        XCTAssertEqual(done, [.completeToolCall(id: "call_1", name: "read_file", arguments: "{\"path\":\"README.md\"}")])
    }

    func testStreamParserThrowsOnFailureEvent() {
        var parser = CodexStreamParser()
        XCTAssertThrowsError(try parser.consume(eventJSON: #"{"type":"response.failed","error":"nope"}"#))
    }
}
