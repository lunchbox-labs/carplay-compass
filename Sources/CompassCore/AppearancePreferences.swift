import Foundation

/// The iPhone app's color scheme; system-owned surfaces keep their host appearance.
public enum AppTheme: String, CaseIterable, Codable, Sendable {
  case system, light, dark
}

/// Presentations that can follow global appearance or store a whole-surface override.
public enum AppearanceSurface: String, CaseIterable, Codable, Sendable {
  case phone, activity
}

/// Position of the four cardinal rim labels, independent of center text.
public enum CardinalLabels: String, CaseIterable, Codable, Sendable {
  case inside, outside, hidden
}

/// Which part of the dial follows the current bearing.
public enum DialRotation: String, CaseIterable, Codable, Sendable {
  case dial, arrow
}

/// How a rotating dial behaves while the system Reduce Motion setting is on.
public enum ReducedMotionDial: String, CaseIterable, Codable, Sendable {
  /// Replace the dial with a steady text reading that keeps direction and degrees current.
  case steadyReadout
  /// Keep the dial; the phone then moves it in steps of a few degrees instead of continuously,
  /// so a settled reading can differ from the sensor by up to one step.
  case rotatingDial
}

/// Number of interior marks between adjacent cardinal major ticks.
public enum MinorTicks: Int, CaseIterable, Codable, Sendable {
  case none = 0, five = 5, eight = 8, seventeen = 17

  /// Four major ticks, with the selected number of interior marks in each quarter.
  public var angles: [Double] {
    (0..<(4 * (rawValue + 1))).map { Double($0) * 90 / Double(rawValue + 1) }
  }
}

/// The twelve Dynamic Type categories available for a custom readout size, in ascending order.
///
/// Raw values are stable storage identifiers; the five accessibility categories extend the
/// original seven standard categories so saved choices keep their meaning.
public enum ReadoutTextSize: Int, CaseIterable, Codable, Sendable {
  case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
  case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

  /// Whether this is one of the system's accessibility text size categories.
  public var isAccessibilitySize: Bool { rawValue > Self.xxxLarge.rawValue }
}

/// Display-only choices; never contains sensor samples or validity timestamps.
public struct AppearanceValues: Codable, Hashable, Sendable {
  /// Shows the abbreviated direction in the readout.
  public var showDirection = true
  /// Shows numerical degrees in the readout.
  public var showDegrees = true
  /// Follows the presentation environment's Dynamic Type category when enabled.
  public var useSystemTextSize = true
  /// Readout-only category used when system sizing is disabled.
  public var customTextSize: ReadoutTextSize = .large
  /// Interior tick density in each quarter.
  public var minorTicks: MinorTicks = .seventeen
  /// Cardinal rim-label placement.
  public var labels: CardinalLabels = .inside
  /// Rotating dial or rotating arrow.
  public var rotation: DialRotation = .dial
  /// Presentation used while the system Reduce Motion setting is on.
  public var reducedMotionDial: ReducedMotionDial = .steadyReadout

  /// Creates the standard appearance.
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case showDirection, showDegrees, useSystemTextSize, customTextSize, minorTicks, labels
    case rotation, reducedMotionDial
  }

  /// Decodes saved values, keeping the standard choice for keys an earlier version did not store.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let standard = Self()
    showDirection =
      try values.decodeIfPresent(Bool.self, forKey: .showDirection) ?? standard.showDirection
    showDegrees =
      try values.decodeIfPresent(Bool.self, forKey: .showDegrees) ?? standard.showDegrees
    useSystemTextSize =
      try values.decodeIfPresent(Bool.self, forKey: .useSystemTextSize)
      ?? standard.useSystemTextSize
    customTextSize =
      try values.decodeIfPresent(ReadoutTextSize.self, forKey: .customTextSize)
      ?? standard.customTextSize
    minorTicks =
      try values.decodeIfPresent(MinorTicks.self, forKey: .minorTicks) ?? standard.minorTicks
    labels = try values.decodeIfPresent(CardinalLabels.self, forKey: .labels) ?? standard.labels
    rotation = try values.decodeIfPresent(DialRotation.self, forKey: .rotation) ?? standard.rotation
    reducedMotionDial =
      try values.decodeIfPresent(ReducedMotionDial.self, forKey: .reducedMotionDial)
      ?? standard.reducedMotionDial
  }

  /// Whether any central reading is visible.
  public var hasReadout: Bool { showDirection || showDegrees }

  /// Recovers direction-only presentation if both fields were disabled.
  public func requiringReadout() -> Self {
    var value = self
    if !value.hasReadout { value.showDirection = true }
    return value
  }
}

/// One optional override per surface; nil means follow the current global values.
public struct AppearancePreferences: Codable, Hashable, Sendable {
  /// App-wide theme, independent of per-surface dial and readout overrides.
  public var theme: AppTheme = .system
  /// Shared values used by surfaces without an override.
  public private(set) var global = AppearanceValues()
  private var phone: AppearanceValues?
  private var activity: AppearanceValues?

  /// Creates the standard appearance.
  public init() {}

  private enum CodingKeys: String, CodingKey { case global, phone, activity, theme }

  /// Older preferences follow the system without discarding saved dial and readout choices.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    global = try values.decode(AppearanceValues.self, forKey: .global)
    phone = try values.decodeIfPresent(AppearanceValues.self, forKey: .phone)
    activity = try values.decodeIfPresent(AppearanceValues.self, forKey: .activity)
    let storedTheme = try values.decodeIfPresent(String.self, forKey: .theme)
    theme = storedTheme.flatMap(AppTheme.init(rawValue:)) ?? .system
  }

  /// Whether a surface follows subsequent global changes.
  public func usesGlobal(for surface: AppearanceSurface) -> Bool {
    override(for: surface) == nil
  }

  /// Resolves a surface, preserving the text-only activity constraint.
  public func effective(for surface: AppearanceSurface) -> AppearanceValues {
    let value = override(for: surface) ?? global.requiringReadout()
    return surface == .activity ? value.requiringReadout() : value
  }

  /// Updates shared values while retaining a usable Live Activity reading.
  public mutating func setGlobal(_ value: AppearanceValues) {
    global = value.requiringReadout()
  }

  /// Discards the override, or starts a fresh copy of the current global values.
  public mutating func setUsesGlobal(_ usesGlobal: Bool, for surface: AppearanceSurface) {
    // Starting a new customization always copies today's global values.
    set(usesGlobal ? nil : global.requiringReadout(), for: surface)
  }

  /// Stores a complete local choice, enforcing the activity readout constraint.
  public mutating func setOverride(_ value: AppearanceValues, for surface: AppearanceSurface) {
    set(surface == .activity ? value.requiringReadout() : value, for: surface)
  }

  /// Loads persisted choices, recovering safely from unsupported or corrupt data.
  public static func decode(_ data: Data?) -> Self {
    guard let data, var preferences = try? JSONDecoder().decode(Self.self, from: data) else {
      return Self()
    }
    preferences.global = preferences.global.requiringReadout()
    preferences.activity = preferences.activity?.requiringReadout()
    return preferences
  }

  private func override(for surface: AppearanceSurface) -> AppearanceValues? {
    switch surface {
    case .phone: phone
    case .activity: activity
    }
  }

  private mutating func set(_ value: AppearanceValues?, for surface: AppearanceSurface) {
    switch surface {
    case .phone: phone = value
    case .activity: activity = value
    }
  }
}
