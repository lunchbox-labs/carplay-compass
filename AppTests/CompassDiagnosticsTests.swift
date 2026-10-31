import Foundation
import SQLite3
import XCTest
@testable import Compass

final class CompassDiagnosticsTests: XCTestCase {
  private func makeStore() throws -> CompassDiagnostics {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: url.path + suffix)
      }
    }
    return try CompassDiagnostics(url: url)
  }

  func testUpgradeDropsWidgetRecordsAndKeepsActivityDiagnostics() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.record(.activity, kind: .updateCompleted, wall: 100, uptime: 100)
    let retained = try store.snapshot().events
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(store.url.path, &database), SQLITE_OK)
    defer { sqlite3_close(database) }
    let legacy = """
      CREATE TABLE widget_events (sequence INTEGER PRIMARY KEY, wall REAL, payload TEXT);
      INSERT INTO widget_events VALUES (1, 100, '{}');
      INSERT INTO events(surface,kind,wall,uptime,elapsed,session)
        VALUES ('widget','reloadRequested',100,100,0,'legacy');
      INSERT INTO clocks VALUES ('widget',0,100,100,'old','legacy',1);
      """
    XCTAssertEqual(sqlite3_exec(database, legacy, nil, nil, nil), SQLITE_OK)
    let upgraded = try CompassDiagnostics(url: store.url)
    XCTAssertTrue(try upgraded.isEnabled())
    let snapshot = try upgraded.snapshot()
    XCTAssertEqual(snapshot.events, retained)
    XCTAssertTrue(snapshot.events.allSatisfy { $0.surface == .activity })
    XCTAssertTrue(snapshot.events.contains { $0.kind == .updateCompleted })
    let exported = try JSONDecoder().decode(
      CompassDiagnostics.Snapshot.self, from: upgraded.exportJSON())
    XCTAssertEqual(exported.events, retained)
    XCTAssertEqual(Set(exported.surfaces.map(\.surface)), [.activity, .fullscreen])
    // Export filtering is not enough: upgrading must delete the retired stored data too.
    var query: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*) FROM sqlite_master WHERE name='widget_events'", -1, &query, nil), SQLITE_OK
    )
    defer { sqlite3_finalize(query) }
    XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(query, 0), 0)
    var legacyRows: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database,
        "SELECT (SELECT COUNT(*) FROM events WHERE surface='widget') + (SELECT COUNT(*) FROM clocks WHERE surface='widget')",
        -1, &legacyRows, nil), SQLITE_OK)
    defer { sqlite3_finalize(legacyRows) }
    XCTAssertEqual(sqlite3_step(legacyRows), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(legacyRows, 0), 0)
    XCTAssertNoThrow(try CompassDiagnostics(url: store.url).exportJSON())
  }

  func testRetiredSampleCleanupPreservesOtherSharedDataAndIsRepeatable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let retired = root.appendingPathComponent("LatestCourse", isDirectory: true)
    try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
    try Data("old reading".utf8).write(to: retired.appendingPathComponent("latest.json"))
    let retained = root.appendingPathComponent("preferences")
    try Data("retained".utf8).write(to: retained)
    try RetiredWidgetData.remove(from: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "retained")
    XCTAssertNoThrow(try RetiredWidgetData.remove(from: root))
  }

  func testRetentionUsesSeparateActiveClocksAndDoesNotCountIdleGaps() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    try store.record(.activity, kind: .updateCompleted, wall: 100, uptime: 100)
    for second in 1...1801 {
      try store.observe(
        .fullscreen, active: true, wall: Double(100 + second), uptime: Double(100 + second))
    }
    let snapshot = try store.snapshot()
    XCTAssertFalse(
      snapshot.events.contains { $0.surface == .fullscreen && $0.kind == .templateUpdated })
    XCTAssertTrue(
      snapshot.events.contains { $0.surface == .activity && $0.kind == .updateCompleted })
    try store.observe(.activity, active: true, wall: 100_000, uptime: 100_000)
    XCTAssertEqual(
      try store.snapshot().surfaces.first { $0.surface == .activity }?.activeSeconds, 0)
  }

  func testDisableClearsLogsAndClocksWithoutReenablingCollection() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    XCTAssertFalse(try store.snapshot().events.isEmpty)
    try store.setEnabled(false)
    XCTAssertFalse(try store.record(.fullscreen, kind: .updateRequested, wall: 101, uptime: 101))
    try store.observe(.fullscreen, active: true, wall: 102, uptime: 102)
    let cleared = try store.snapshot()
    XCTAssertTrue(cleared.events.isEmpty)
    XCTAssertTrue(cleared.surfaces.allSatisfy { $0.activeSeconds == 0 })
    XCTAssertFalse(try CompassDiagnostics(url: store.url).isEnabled())
    try store.clear()
    XCTAssertFalse(try store.isEnabled())
  }

  func testDelayedCompletionCannotEnterNewRecordingSessionAfterDisableOrClear() throws {
    for disable in [true, false] {
      let store = try makeStore()
      try store.setEnabled(true)
      try store.observe(.activity, active: true, wall: 100, uptime: 100)
      let oldSession = try XCTUnwrap(store.recordingSession(.activity))
      XCTAssertTrue(
        try store.record(
          .activity, kind: .updateRequested, matchingSession: oldSession, wall: 100, uptime: 100))
      if disable {
        try store.setEnabled(false)
        XCTAssertNil(try store.recordingSession(.activity))
        try store.setEnabled(true)
      } else {
        try store.clear()
        XCTAssertTrue(try store.isEnabled())
      }
      try store.observe(.activity, active: true, wall: 101, uptime: 101)
      let currentSession = try XCTUnwrap(store.recordingSession(.activity))
      XCTAssertNotEqual(oldSession, currentSession)
      XCTAssertFalse(
        try store.record(
          .activity, kind: .updateCompleted, matchingSession: oldSession, wall: 101, uptime: 101))
      XCTAssertTrue(
        try store.record(
          .activity, kind: .updateCompleted, matchingSession: currentSession, wall: 101, uptime: 101
        ))
      XCTAssertTrue(try store.snapshot().events.allSatisfy { $0.session == currentSession })
    }
  }

  func testDisableSerializesWithConcurrentWritersOnAnotherConnection() throws {
    let store = try makeStore()
    let writer = try CompassDiagnostics(url: store.url)
    try store.setEnabled(true)
    try writer.observe(.activity, active: true, wall: 100, uptime: 100)
    DispatchQueue.concurrentPerform(iterations: 20) { index in
      do {
        if index == 0 {
          try store.setEnabled(false)
        } else {
          try writer.observe(.activity, active: true, wall: 101, uptime: 101)
          try writer.record(.activity, kind: .updateCompleted, wall: 101, uptime: 101)
        }
      } catch { XCTFail("Concurrent disable/write failed: \(error)") }
    }
    XCTAssertFalse(try store.isEnabled())
    XCTAssertTrue(try store.snapshot().events.isEmpty)
    XCTAssertTrue(try store.snapshot().surfaces.allSatisfy { $0.activeSeconds == 0 })
  }

  func testFailedClearDoesNotPretendDebugModeWasDisabled() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.activity, active: true, wall: 100, uptime: 100)
    let retained = try store.snapshot().events
    var connection: OpaquePointer?
    XCTAssertEqual(sqlite3_open(store.url.path, &connection), SQLITE_OK)
    defer { sqlite3_close(connection) }
    XCTAssertEqual(
      sqlite3_exec(
        connection,
        "CREATE TRIGGER fail_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'fixture'); END;",
        nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try store.setEnabled(false))
    XCTAssertTrue(try store.isEnabled())
    XCTAssertEqual(try store.snapshot().events, retained)
  }

  func testPauseResumeAndRestartExcludeIdleTimeFromIntervals() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
    try store.observe(.fullscreen, active: true, wall: 101, uptime: 101)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 101, uptime: 101)
    try store.observe(.fullscreen, active: false, wall: 102, uptime: 102)
    try store.observe(.fullscreen, active: true, wall: 10_000, uptime: 10_000)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 10_000, uptime: 10_000)
    let restarted = try CompassDiagnostics(url: store.url)
    try restarted.observe(.fullscreen, active: true, wall: 10_001, uptime: 10_001)
    let summary = try XCTUnwrap(restarted.snapshot().surfaces.first { $0.surface == .fullscreen })
    XCTAssertEqual(summary.activeSeconds, 2)
    XCTAssertEqual(summary.intervals.first { $0.kind == .templateUpdated }?.meanIntervalSeconds, 1)
    try restarted.clear()
    XCTAssertTrue(try restarted.isEnabled())
    try restarted.observe(.fullscreen, active: true, wall: 10_002, uptime: 10_002)
    XCTAssertEqual(
      try restarted.snapshot().surfaces.first { $0.surface == .fullscreen }?.activeSeconds, 0)
  }

  func testExportContainsElapsedIntervalsWithoutRawBootUptime() throws {
    let store = try makeStore()
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 987654)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 987654)
    try store.observe(.fullscreen, active: true, wall: 101, uptime: 987655)
    try store.record(.fullscreen, kind: .templateUpdated, wall: 101, uptime: 987655)
    let data = try store.exportJSON()
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("987654"))
    XCTAssertFalse(text.contains("987655"))
    let snapshot = try JSONDecoder().decode(CompassDiagnostics.Snapshot.self, from: data)
    XCTAssertEqual(
      snapshot.events.filter { $0.kind == .templateUpdated }.map(\.elapsedSinceFirstRetainedEvent),
      [0, 1])
    XCTAssertEqual(
      snapshot.surfaces.first { $0.surface == .fullscreen }?.intervals.first {
        $0.kind == .templateUpdated
      }?.meanIntervalSeconds, 1)
  }

  func testConcurrentConnectionsExportConsistentEventsAndIntervals() throws {
    let store = try makeStore()
    let secondConnection = try CompassDiagnostics(url: store.url)
    try store.setEnabled(true)
    try store.observe(.fullscreen, active: true, wall: 100, uptime: 100)
    DispatchQueue.concurrentPerform(iterations: 20) { _ in
      do {
        try secondConnection.record(.fullscreen, kind: .updateRequested, wall: 100, uptime: 100)
        let snapshot = try JSONDecoder().decode(
          CompassDiagnostics.Snapshot.self, from: store.exportJSON())
        let summarized = snapshot.surfaces.flatMap(\.intervals).reduce(0) { $0 + $1.count }
        XCTAssertEqual(summarized, snapshot.events.count)
        XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
        try store.record(.fullscreen, kind: .templateUpdated, wall: 100, uptime: 100)
      } catch { XCTFail("Concurrent write failed: \(error)") }
    }
    let data = try store.exportJSON()
    let snapshot = try JSONDecoder().decode(CompassDiagnostics.Snapshot.self, from: data)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .updateRequested }.count, 20)
    XCTAssertEqual(snapshot.events.filter { $0.kind == .templateUpdated }.count, 20)
    XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, snapshot.events.count)
    try store.observe(.fullscreen, active: false, wall: 101, uptime: 101)
    let count = try store.snapshot().events.count
    try secondConnection.record(.fullscreen, kind: .updateRequested, wall: 102, uptime: 102)
    XCTAssertEqual(try store.snapshot().events.count, count)
  }
}
