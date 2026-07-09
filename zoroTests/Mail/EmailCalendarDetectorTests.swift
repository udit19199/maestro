//
//  EmailCalendarDetectorTests.swift
//  zoroTests
//

import XCTest
@testable import zoro

final class EmailCalendarDetectorTests: XCTestCase {
    func testParseICSBasicEvent() {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        DTSTART:20260715T140000Z
        DTEND:20260715T150000Z
        SUMMARY:Team Meeting
        LOCATION:Conference Room A
        DESCRIPTION:Weekly sync
        END:VEVENT
        END:VCALENDAR
        """

        let events = EmailCalendarDetector.parseICS(ics)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Team Meeting")
        XCTAssertEqual(events[0].location, "Conference Room A")
        XCTAssertEqual(events[0].notes, "Weekly sync")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: events[0].startDate)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 0)
    }

    func testParseICSWithDuration() {
        let ics = """
        BEGIN:VEVENT
        DTSTART:20260715T140000Z
        DURATION:PT1H30M
        SUMMARY:Long Meeting
        END:VEVENT
        """

        let events = EmailCalendarDetector.parseICS(ics)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Long Meeting")
        XCTAssertEqual(events[0].endDate.timeIntervalSince(events[0].startDate), 5400, accuracy: 1)
    }

    func testParseICSUnfoldsWrappedLines() {
        let ics = """
        BEGIN:VEVENT
        DTSTART:20260720T090000Z
        DTEND:20260720T100000Z
        SUMMARY:Project Kickoff
          with the design team
        END:VEVENT
        """

        let events = EmailCalendarDetector.parseICS(ics)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Project Kickoff with the design team")
    }

    func testProposalsFromHeuristicsWithEmbeddedICS() {
        let subject = "Invitation: Quarterly review"
        let snippet = """
        Please join us.
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        DTSTART:20260801T160000Z
        DTEND:20260801T170000Z
        SUMMARY:Quarterly review
        END:VEVENT
        END:VCALENDAR
        """

        let proposals = EmailCalendarDetector.proposalsFromHeuristics(
            subject: subject,
            snippet: snippet,
            from: "hr@company.com"
        )

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].title, "Quarterly review")
        XCTAssertTrue(proposals[0].startDate.contains("2026"))
    }

    func testProposalsFromHeuristicsReturnsEmptyForNonInvite() {
        let proposals = EmailCalendarDetector.proposalsFromHeuristics(
            subject: "Invoice attached",
            snippet: "Please review the attached PDF.",
            from: "billing@example.com"
        )

        XCTAssertTrue(proposals.isEmpty)
    }
}
