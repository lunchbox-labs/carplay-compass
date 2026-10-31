import ActivityKit
import Combine
import CompassCore
import Foundation

@MainActor
protocol CompassActivityHandle: AnyObject {
  var onDismiss: (() -> Void)? { get set }
  func update(_ state: CompassActivityAttributes.ContentState) async
  func end(_ finalState: CompassActivityAttributes.ContentState) async
}

@MainActor
protocol CompassActivitySystem: AnyObject {
  var enabled: Bool { get }
  func request(_ state: CompassActivityAttributes.ContentState) async throws
    -> any CompassActivityHandle
  func endSurvivors(_ finalState: CompassActivityAttributes.ContentState) async
}

/// Owns only the current compact presentation. Call start from eligible CarPlay activation.
@MainActor
final class CompassActivityController: CompassActivityPresenting {
  enum Failure: Error { case unavailable, cancelled }
  var onDismiss: (() -> Void)?
  private let system: any CompassActivitySystem
  private let now: () -> Date
  private var handle: (any CompassActivityHandle)?
  private var starting = false
  private var generation = UUID()
  private var validity = UUID()
  private var lastUsableWrite: Date?
  private var operation: Task<Void, Never>?
  private var appearance: AppearanceValues
  private var appearanceObservation: AnyCancellable?
  private var lastContent: CompassActivityAttributes.ContentState?

  init(
    system: any CompassActivitySystem = LocalCompassActivitySystem(),
    now: @escaping () -> Date = Date.init,
    appearanceStore: AppearanceStore = .shared
  ) {
    self.system = system
    self.now = now
    appearance = appearanceStore.preferences.effective(for: .activity)
    appearanceObservation = appearanceStore.$preferences
      .map { $0.effective(for: .activity) }.removeDuplicates().dropFirst()
      .sink { [weak self] value in
        self?.updateAppearance(value)
      }
  }

  func start() async throws {
    guard handle == nil else { return }
    guard !starting else { throw Failure.unavailable }
    guard system.enabled else { throw Failure.unavailable }
    starting = true
    let token = generation
    do {
      var initial = CompassActivityAttributes.ContentState(bearing: nil, status: .waiting)
      initial.appearance = appearance
      let created = try await system.request(initial)
      guard generation == token else {
        await created.end(.init(bearing: nil, status: .unavailable))
        throw Failure.cancelled
      }
      handle = created
      lastContent = initial
      try? CompassDiagnostics.shared?.observe(.activity, active: true)
      starting = false
      created.onDismiss = { [weak self] in
        guard let self, self.generation == token else { return }
        self.generation = UUID()
        self.handle = nil
        self.lastContent = nil
        try? CompassDiagnostics.shared?.observe(.activity, active: false)
        self.lastUsableWrite = nil
        self.scheduledReading = nil
        self.onDismiss?()
      }
      if initial.appearance != appearance { await updateAppearance(appearance)?.value }
    } catch {
      if generation == token { starting = false }
      throw error
    }
  }

  /// This is a sampled last-reading display, not a promise of live vehicle orientation.
  /// Unchanged readings need no expiry heartbeat; changed readings remain rate-limited.
  static let changedReadingInterval: TimeInterval = 1

  private struct ScheduledReading {
    let bearing: Double
    let token = UUID()
  }
  private var scheduledReading: ScheduledReading?

  func update(_ presentation: TravelPresentation) async {
    await publish(presentation, retainLastReading: true)
  }

  func invalidateReading() async {
    await publish(.init(sample: nil, status: .unavailable), retainLastReading: false)
  }

  private func publish(_ presentation: TravelPresentation, retainLastReading: Bool) async {
    guard let handle else { return }
    let date = now()
    let state = Self.content(presentation, now: date)
    let expiredTravelSample =
      presentation.sample.map {
        $0.source == .vehicleCourse && $0.reference == .trueNorth
          && date.timeIntervalSince1970.isFinite && date.timeIntervalSince($0.timestamp) > 5
      } ?? false
    if state.bearing == nil, retainLastReading, scheduledReading != nil,
      (presentation.status != .usable || expiredTravelSample), presentation.status != .waiting
    {
      return
    }
    if let bearing = state.bearing {
      if let lastUsableWrite, date.timeIntervalSince(lastUsableWrite) < Self.changedReadingInterval
      {
        return
      }
      if let scheduledReading, Self.sameReading(scheduledReading.bearing, bearing) {
        return
      }
      lastUsableWrite = date
      scheduledReading = ScheduledReading(bearing: bearing)
    } else {
      validity = UUID()
      scheduledReading = nil
    }
    let validityToken = validity
    let readingToken = scheduledReading?.token
    let token = generation
    let previous = operation
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, self.generation == token,
        state.bearing == nil || self.validity == validityToken
      else { return }
      // Revalidate after waiting so an expired sample never becomes a new bearing.
      var content = Self.content(presentation, now: self.now())
      if state.bearing != nil, content.bearing == nil {
        // Do not replace the last accepted reading with a sample that expired in the queue.
        if self.scheduledReading?.token == readingToken {
          self.scheduledReading = self.lastContent?.bearing.map { ScheduledReading(bearing: $0) }
        }
        return
      }
      content.appearance = self.appearance
      self.lastContent = content
      await handle.update(content)
    }
    operation = task
    await task.value
  }

  /// Changes only presentation, serialized with course updates and teardown.
  @discardableResult
  func updateAppearance(_ value: AppearanceValues) -> Task<Void, Never>? {
    appearance = value.requiringReadout()
    guard let handle else { return nil }
    let token = generation
    let validityToken = validity
    let previous = operation
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, self.generation == token, self.validity == validityToken,
        var content = self.lastContent
      else { return }
      content.appearance = self.appearance
      // Retained content keeps its original sample time; a cosmetic update is not a new sample.
      self.lastContent = content
      await handle.update(content)
    }
    operation = task
    return task
  }

  func end() async {
    generation = UUID()
    starting = false
    lastUsableWrite = nil
    scheduledReading = nil
    let owned = handle
    handle = nil
    lastContent = nil
    try? CompassDiagnostics.shared?.observe(.activity, active: false)
    owned?.onDismiss = nil
    let previous = operation
    let system = system
    let task = Task { @MainActor in
      await previous?.value
      let finalState = CompassActivityAttributes.ContentState(bearing: nil, status: .unavailable)
      await owned?.end(finalState)
      await system.endSurvivors(finalState)
    }
    operation = task
    await task.value
  }

  /// Whether two bearings render the same rounded degrees and the same cardinal direction.
  static func sameReading(_ first: Double, _ second: Double) -> Bool {
    Int(first.rounded()) % 360 == Int(second.rounded()) % 360
      && CompassPoint(degrees: first) == CompassPoint(degrees: second)
  }

  static func content(_ presentation: TravelPresentation, now: Date)
    -> CompassActivityAttributes.ContentState
  {
    let status: CompassActivityAttributes.Status
    switch presentation.status {
    case .waiting: status = .waiting
    case .usable: status = .usable
    case .slow: status = .slow
    case .unreliable: status = .unreliable
    case .unavailable: status = .unavailable
    }
    guard status == .usable, let sample = presentation.sample,
      sample.source == .vehicleCourse, sample.reference == .trueNorth,
      sample.angle.degrees.isFinite, (0..<360).contains(sample.angle.degrees),
      now.timeIntervalSince1970.isFinite, sample.timestamp.timeIntervalSince1970.isFinite,
      (0...5).contains(now.timeIntervalSince(sample.timestamp))
    else { return .init(bearing: nil, status: status == .usable ? .unavailable : status) }
    return .init(
      bearing: sample.angle.degrees, status: .usable, sampleTime: sample.timestamp,
      expiry: nil)
  }
}

@MainActor
private final class LocalCompassActivitySystem: CompassActivitySystem {
  var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
  func request(_ state: CompassActivityAttributes.ContentState) async throws
    -> any CompassActivityHandle
  {
    let activity = try Activity.request(
      attributes: CompassActivityAttributes(),
      content: ActivityContent(state: state, staleDate: state.expiry), pushType: nil)
    return LocalCompassActivityHandle(activity)
  }
  func endSurvivors(_ finalState: CompassActivityAttributes.ContentState) async {
    for activity in Activity<CompassActivityAttributes>.activities {
      await activity.end(
        ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
    }
  }
}

@MainActor
private final class LocalCompassActivityHandle: CompassActivityHandle {
  var onDismiss: (() -> Void)?
  private let activityID: String
  private var observer: Task<Void, Never>?
  init(_ activity: Activity<CompassActivityAttributes>) {
    activityID = activity.id
    observer = Task { @MainActor [weak self] in
      for await state in activity.activityStateUpdates {
        guard !Task.isCancelled else { return }
        if state == .dismissed || state == .ended { self?.onDismiss?(); return }
      }
    }
  }
  deinit { observer?.cancel() }
  func update(_ state: CompassActivityAttributes.ContentState) async {
    await Self.update(activityID: activityID, state: state)
  }
  func end(_ finalState: CompassActivityAttributes.ContentState) async {
    observer?.cancel()
    onDismiss = nil
    await Self.end(activityID: activityID, finalState: finalState)
  }

  // Resolve the SDK handle locally so a retained main-actor value never crosses
  // into ActivityKit's concurrent update/end operations.
  nonisolated private static func update(
    activityID: String, state: CompassActivityAttributes.ContentState
  ) async {
    guard
      let activity = Activity<CompassActivityAttributes>.activities.first(where: {
        $0.id == activityID
      })
    else { return }
    var content = state
    if (try? CompassDiagnostics.shared?.isEnabled()) == true {
      content.debugUpdateTime = Date()
    }
    let diagnostics = CompassDiagnostics.shared
    let recordingSession = try? diagnostics?.recordingSession(.activity)
    if let recordingSession {
      _ = try? diagnostics?.record(
        .activity, kind: .updateRequested, matchingSession: recordingSession)
    }
    await activity.update(ActivityContent(state: content, staleDate: content.expiry))
    if let recordingSession {
      _ = try? diagnostics?.record(
        .activity, kind: .updateCompleted, matchingSession: recordingSession)
    }
  }

  nonisolated private static func end(
    activityID: String, finalState: CompassActivityAttributes.ContentState
  ) async {
    guard
      let activity = Activity<CompassActivityAttributes>.activities.first(where: {
        $0.id == activityID
      })
    else { return }
    await activity.end(
      ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
  }
}
