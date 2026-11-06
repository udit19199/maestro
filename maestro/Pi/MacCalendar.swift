import EventKit
import Foundation

/// Runs the calendar tools from maestro-pi.ts on the Mac's calendars, which sync Google Calendar
/// once the account is added in System Settings > Internet Accounts.
// ponytail: new events go to the default calendar; no invites (EventKit cannot add attendees),
// and changes to a repeating event touch only the first occurrence.
@MainActor
enum MacCalendar {
  static let store = EKEventStore()

  private struct Request: Decodable {
    let action: String
    var id: String?
    var from: String?
    var to: String?
    var summary: String?
    var start: String?
    var end: String?
    var notes: String?
    var location: String?
  }

  static var allowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
  static func requestAccess() async -> Bool {
    (try? await store.requestFullAccessToEvents()) ?? false
  }

  /// Takes the tool's JSON request and returns JSON: the result, or {"error": "..."}.
  static func handle(_ json: String) async -> String {
    var reply: Any
    do {
      let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
      guard await requestAccess() else {
        throw PiError.message(
          "Maestro cannot use your calendar. Allow it in System Settings > Privacy & Security > Calendars.")
      }
      reply = try run(request)
    } catch {
      reply = ["error": error.localizedDescription]
    }
    let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  private static func run(_ request: Request) throws -> Any {
    switch request.action {
    case "list":
      let from = try date(request.from)
      let to = try date(request.to)
      let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
      return events.map(describe)
    case "get":
      return describe(try event(request.id))
    case "create":
      let event = EKEvent(eventStore: store)
      event.calendar = store.defaultCalendarForNewEvents
      try apply(request, to: event)
      try store.save(event, span: .thisEvent)
      return ["created": event.eventIdentifier ?? ""]
    case "update":
      let event = try event(request.id)
      try apply(request, to: event)
      try store.save(event, span: .thisEvent)
      return ["updated": event.eventIdentifier ?? ""]
    case "delete":
      try store.remove(try event(request.id), span: .thisEvent)
      return ["deleted": request.id ?? ""]
    default:
      throw PiError.message("Unknown calendar action \(request.action).")
    }
  }

  private static func event(_ id: String?) throws -> EKEvent {
    guard let id, let event = store.event(withIdentifier: id) else {
      throw PiError.message("No calendar event with id \(id ?? "").")
    }
    return event
  }

  private static func apply(_ request: Request, to event: EKEvent) throws {
    if let summary = request.summary { event.title = summary }
    if let notes = request.notes { event.notes = notes }
    if let location = request.location { event.location = location }
    if let start = request.start {
      event.isAllDay = start.count == 10
      event.startDate = try date(start)
    }
    // An all-day end is exclusive ("2026-11-06" ends on the 5th); EventKit's is inclusive.
    if let end = request.end { event.endDate = try date(end).addingTimeInterval(end.count == 10 ? -1 : 0) }
    if event.endDate == nil || event.endDate < event.startDate { event.endDate = event.startDate }
  }

  private static func date(_ value: String?) throws -> Date {
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    let time = ISO8601DateFormatter()
    guard let value, let date = value.count == 10 ? day.date(from: value) : time.date(from: value) else {
      throw PiError.message("\"\(value ?? "")\" is not a date like 2026-11-05T15:00:00+05:30 or 2026-11-05.")
    }
    return date
  }

  private static func describe(_ event: EKEvent) -> [String: Any] {
    let time = ISO8601DateFormatter()
    time.timeZone = .current
    var values: [String: Any] = [
      "id": event.eventIdentifier ?? "", "summary": event.title ?? "", "calendar": event.calendar.title,
      "start": time.string(from: event.startDate), "end": time.string(from: event.endDate),
      "allDay": event.isAllDay,
    ]
    if let location = event.location, !location.isEmpty { values["location"] = location }
    if let attendees = event.attendees, !attendees.isEmpty {
      values["attendees"] = attendees.map { "\($0.name ?? $0.url.absoluteString)" }
    }
    return values
  }
}
