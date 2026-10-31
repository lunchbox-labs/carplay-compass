import Foundation
import SQLite3

/// Local timing evidence only. An event never proves that CarPlay painted a frame.
final class CompassDiagnostics: @unchecked Sendable {
  enum Surface: String, Codable, CaseIterable { case activity, fullscreen }
  enum Kind: String, Codable {
    case started, paused, updateRequested, updateCompleted
    case templateUpdated
  }
  struct Event: Codable, Equatable {
    let sequence: Int64
    let surface: Surface
    let kind: Kind
    let timestamp: Double
    let elapsedSinceFirstRetainedEvent: Double
    let activeSeconds: Double
    let session: String
  }
  struct IntervalSummary: Codable {
    let kind: Kind
    let count: Int
    let meanIntervalSeconds: Double?
  }
  struct SurfaceSummary: Codable {
    let surface: Surface
    let activeSeconds: Double
    let intervals: [IntervalSummary]
  }
  struct Snapshot: Codable {
    let explanation: String
    let surfaces: [SurfaceSummary]
    let events: [Event]
  }
  enum Failure: Error, LocalizedError {
    case unavailable, database
    var errorDescription: String? {
      switch self {
      case .unavailable: "Shared diagnostics are unavailable. Check the app’s App Group signing."
      case .database: "The local diagnostics store could not be read or written."
      }
    }
  }

  static let group = "group.dev.lunchbox-labs.carplay-compass"
  static let shared: CompassDiagnostics? = {
    #if os(iOS)
      guard
        var directory = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: group)
      else { return nil }
      directory.appendPathComponent("Diagnostics", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: directory.path)
        return try CompassDiagnostics(url: directory.appendingPathComponent("timing.sqlite"))
      } catch { return nil }
    #else
      return nil
    #endif
  }()

  let url: URL
  private let database: OpaquePointer
  private let lock = NSLock()
  private let process = UUID().uuidString
  private var lastObservation: [Surface: (uptime: Double, active: Bool)] = [:]

  init(url: URL) throws {
    self.url = url
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path, &handle,
        SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let handle
    else {
      if let handle { sqlite3_close(handle) }
      throw Failure.database
    }
    database = handle
    sqlite3_busy_timeout(handle, 100)
    do {
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA journal_size_limit=1048576")
      try execute(
        "CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, enabled INTEGER NOT NULL)")
      try execute("INSERT OR IGNORE INTO settings VALUES (1, 0)")
      try execute(
        """
        CREATE TABLE IF NOT EXISTS clocks (
          surface TEXT PRIMARY KEY, total REAL NOT NULL, wall REAL NOT NULL,
          uptime REAL NOT NULL, owner TEXT NOT NULL, session TEXT NOT NULL, active INTEGER NOT NULL)
        """)
      try execute(
        """
        CREATE TABLE IF NOT EXISTS events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, surface TEXT NOT NULL, kind TEXT NOT NULL,
          wall REAL NOT NULL, uptime REAL NOT NULL, elapsed REAL NOT NULL, session TEXT NOT NULL)
        """)
      try execute("CREATE INDEX IF NOT EXISTS events_surface ON events(surface, elapsed)")
      try transaction {
        try execute("DELETE FROM events WHERE surface='widget'")
        try execute("DELETE FROM clocks WHERE surface='widget'")
        try execute("DROP TABLE IF EXISTS widget_events")
      }
    } catch {
      sqlite3_close(handle)
      throw error
    }
  }
  deinit { sqlite3_close(database) }

  func isEnabled() throws -> Bool {
    try locked { try enabled() }
  }

  func setEnabled(_ value: Bool) throws {
    try transaction {
      try execute("UPDATE settings SET enabled=? WHERE id=1", [value ? "1" : "0"])
      if !value {
        // Disable and erase under the same write lock, including other SQLite connections.
        try execute("DELETE FROM events")
        try execute("DELETE FROM clocks")
      } else {
        // Resume on the next lifecycle tick, never from an old wall-clock timestamp.
        try execute("UPDATE clocks SET active=0")
      }
      lastObservation.removeAll()
    }
  }

  /// Called by existing lifecycle ticks, not by an extra timer. Gaps are not assumed active.
  func observe(
    _ surface: Surface, active: Bool,
    wall: Double = Date().timeIntervalSince1970,
    uptime: Double = ProcessInfo.processInfo.systemUptime
  ) throws {
    guard wall.isFinite, uptime.isFinite else { return }
    let due = locked {
      if let previous = lastObservation[surface], previous.active == active,
        (0..<1).contains(uptime - previous.uptime)
      {
        return false
      }
      lastObservation[surface] = (uptime, active)
      return true
    }
    guard due, try isEnabled() else { return }
    try transaction {
      guard try enabled() else { return }
      let row = try rows(
        "SELECT total,wall,uptime,owner,session,active FROM clocks WHERE surface=?",
        [surface.rawValue]
      ).first
      var total = row.flatMap { Double($0[0]) } ?? 0
      let wasActive = row?[5] == "1"
      guard active || wasActive else { return }
      let delta = uptime - (row.flatMap { Double($0[2]) } ?? uptime)
      let continuing = wasActive && row?[3] == process && (0...2).contains(delta)
      if continuing { total += delta }
      let session = continuing ? (row?[4] ?? UUID().uuidString) : UUID().uuidString
      try execute(
        "INSERT OR REPLACE INTO clocks VALUES (?,?,?,?,?,?,?)",
        [
          surface.rawValue, String(total), String(wall), String(uptime), process, session,
          active ? "1" : "0",
        ])
      if active && !continuing {
        try insert(surface, .started, wall: wall, uptime: uptime, total: total, session: session)
      } else if !active && wasActive {
        try insert(surface, .paused, wall: wall, uptime: uptime, total: total, session: session)
      }
      try prune(surface, total: total)
    }
  }

  /// Capture before asynchronous work so its completion cannot enter a later recording session.
  func recordingSession(_ surface: Surface) throws -> String? {
    try transaction(readOnly: true) {
      guard try enabled() else { return nil }
      return try rows(
        "SELECT session FROM clocks WHERE surface=? AND active=1", [surface.rawValue]
      ).first?.first
    }
  }

  /// Append only while the app has recently observed an eligible feed.
  @discardableResult
  func record(
    _ surface: Surface, kind: Kind, matchingSession: String? = nil,
    wall: Double = Date().timeIntervalSince1970,
    uptime: Double = ProcessInfo.processInfo.systemUptime
  ) throws -> Bool {
    guard wall.isFinite, uptime.isFinite else { return false }
    guard try isEnabled() else { return false }
    return try transaction {
      guard try enabled(),
        let row = try rows(
          "SELECT total,wall,uptime,session,active FROM clocks WHERE surface=?", [surface.rawValue]
        ).first,
        row[4] == "1", matchingSession == nil || matchingSession == row[3],
        let lastUptime = Double(row[2]), let lastWall = Double(row[1]),
        (0...2).contains(uptime - lastUptime), (0...3).contains(wall - lastWall),
        let total = Double(row[0])
      else { return false }
      try insert(surface, kind, wall: wall, uptime: uptime, total: total, session: row[3])
      try prune(surface, total: total)
      return true
    }
  }

  func clear() throws {
    try transaction {
      try execute("DELETE FROM events")
      try execute("DELETE FROM clocks")
      lastObservation.removeAll()
    }
  }

  func snapshot() throws -> Snapshot {
    try transaction(readOnly: true) {
      var origins: [String: Double] = [:]
      for row in try rows("SELECT session,MIN(uptime) FROM events GROUP BY session") {
        origins[row[0]] = Double(row[1])
      }
      let events = try rows(
        "SELECT sequence,surface,kind,wall,uptime,elapsed,session FROM events ORDER BY sequence"
      ).compactMap { row -> Event? in
        guard let sequence = Int64(row[0]), let surface = Surface(rawValue: row[1]),
          let kind = Kind(rawValue: row[2]), let wall = Double(row[3]),
          let uptime = Double(row[4]), let elapsed = Double(row[5])
        else { throw Failure.database }
        let origin = origins[row[6], default: uptime]
        return Event(
          sequence: sequence, surface: surface, kind: kind, timestamp: wall,
          elapsedSinceFirstRetainedEvent: uptime - origin, activeSeconds: elapsed, session: row[6])
      }
      let clocks = try rows("SELECT surface,total FROM clocks")
      let summaries = Surface.allCases.map { surface in
        let selected = events.filter { $0.surface == surface }
        let kinds = Set(selected.map(\.kind.rawValue)).sorted()
        let intervals = kinds.compactMap { name -> IntervalSummary? in
          guard let kind = Kind(rawValue: name) else { return nil }
          let stream = selected.filter { $0.kind == kind }.sorted {
            $0.elapsedSinceFirstRetainedEvent < $1.elapsedSinceFirstRetainedEvent
          }
          var previous: [String: Double] = [:]
          var differences: [Double] = []
          for event in stream {
            if let time = previous[event.session], event.elapsedSinceFirstRetainedEvent >= time {
              differences.append(event.elapsedSinceFirstRetainedEvent - time)
            }
            previous[event.session] = event.elapsedSinceFirstRetainedEvent
          }
          return IntervalSummary(
            kind: kind, count: stream.count,
            meanIntervalSeconds: differences.isEmpty
              ? nil : differences.reduce(0, +) / Double(differences.count))
        }
        let total = clocks.first { $0[0] == surface.rawValue }.flatMap { Double($0[1]) } ?? 0
        return SurfaceSummary(
          surface: surface, activeSeconds: min(1800, total), intervals: intervals)
      }
      return Snapshot(
        explanation:
          "Timing evidence, not screen visibility or paint. Each surface retains up to 30 observed active-feed minutes across sessions (maximum 50000 events). Gaps over 2 seconds and process restarts are not counted. Intervals are grouped by event kind within sessions. Timestamps are Unix seconds. Event elapsed times are relative to the first retained event in that session; raw boot uptime is not exported.",
        surfaces: summaries, events: events)
    }
  }

  func exportJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(snapshot())
  }

  private func enabled() throws -> Bool {
    try rows("SELECT enabled FROM settings WHERE id=1").first?.first == "1"
  }
  private func insert(
    _ surface: Surface, _ kind: Kind, wall: Double, uptime: Double, total: Double, session: String
  ) throws {
    try execute(
      "INSERT INTO events(surface,kind,wall,uptime,elapsed,session) VALUES (?,?,?,?,?,?)",
      [surface.rawValue, kind.rawValue, String(wall), String(uptime), String(total), session])
  }
  private func prune(_ surface: Surface, total: Double) throws {
    try execute(
      "DELETE FROM events WHERE surface=? AND elapsed < ?",
      [surface.rawValue, String(total - 1800)])
    try execute(
      "DELETE FROM events WHERE surface=? AND sequence < COALESCE((SELECT sequence FROM events WHERE surface=? ORDER BY sequence DESC LIMIT 1 OFFSET 49999),0)",
      [surface.rawValue, surface.rawValue])
  }
  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
  private func transaction<T>(readOnly: Bool = false, _ body: () throws -> T) throws -> T {
    try locked {
      try execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
      do {
        let value = try body()
        try execute("COMMIT")
        return value
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
    }
  }
  private func execute(_ sql: String, _ values: [String] = []) throws {
    _ = try rows(sql, values)
  }
  private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw Failure.database }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      let result = value.withCString {
        sqlite3_bind_text(
          statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      guard result == SQLITE_OK else { throw Failure.database }
    }
    var result: [[String]] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        result.append(
          (0..<sqlite3_column_count(statement)).map {
            sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
          })
      case SQLITE_DONE: return result
      default: throw Failure.database
      }
    }
  }
}
