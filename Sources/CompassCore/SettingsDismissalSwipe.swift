/// Completion policy for a right-edge swipe, independent of navigation depth.
public struct SettingsDismissalSwipe {
  private var active = false

  /// Starts with no active swipe.
  public init() {}

  /// Accepts a predominantly leftward initial velocity.
  public mutating func begin(horizontal: Double, vertical: Double) -> Bool {
    active = Self.isLeftward(horizontal: horizontal, vertical: vertical)
    return active
  }

  /// Consumes the gesture and dismisses only beyond the completion threshold.
  public mutating func finish(horizontal: Double, vertical: Double) -> Bool {
    defer { active = false }
    return active && horizontal < -60
      && Self.isLeftward(horizontal: horizontal, vertical: vertical)
  }

  /// Discards an interrupted gesture without dismissing Settings.
  public mutating func cancel() { active = false }

  private static func isLeftward(horizontal: Double, vertical: Double) -> Bool {
    horizontal.isFinite && vertical.isFinite && horizontal < 0
      && abs(vertical) < -horizontal / 2
  }
}
