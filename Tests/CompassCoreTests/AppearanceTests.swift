import CompassCore
import Foundation
import Testing

@Test func appearanceOverridesCopyCurrentGlobalsAndDiscardOldCustomizations() {
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.showDegrees = false
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .phone).showDegrees == false)
  preferences.setUsesGlobal(false, for: .phone)
  var phone = preferences.effective(for: .phone)
  phone.rotation = .arrow
  preferences.setOverride(phone, for: .phone)
  global.showDegrees = true
  global.labels = .outside
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .phone).labels != .outside)
  #expect(preferences.effective(for: .activity).labels == .outside)
  preferences.setUsesGlobal(true, for: .phone)
  #expect(preferences.effective(for: .phone) == preferences.global)
  preferences.setUsesGlobal(false, for: .phone)
  #expect(preferences.effective(for: .phone) == preferences.global)
}

@Test func dialOverridesCanHideBothButGlobalAndActivityKeepAReading() {
  var preferences = AppearancePreferences()
  var hidden = preferences.global
  hidden.showDirection = false
  hidden.showDegrees = false
  preferences.setGlobal(hidden)
  #expect(preferences.global.showDirection)
  preferences.setOverride(hidden, for: .phone)
  #expect(!preferences.effective(for: .phone).hasReadout)
  preferences.setOverride(hidden, for: .activity)
  #expect(preferences.effective(for: .activity).showDirection)
  #expect(!preferences.effective(for: .activity).showDegrees)
}

@Test func appearanceRoundTripAndMalformedStorageRecovery() throws {
  var preferences = AppearancePreferences()
  var custom = preferences.global
  custom.labels = .hidden
  custom.minorTicks = .eight
  preferences.setOverride(custom, for: .phone)
  let data = try JSONEncoder().encode(preferences)
  #expect(AppearancePreferences.decode(data) == preferences)
  #expect(AppearancePreferences.decode(Data("bad json".utf8)).effective(for: .activity).hasReadout)
  // Keep a structurally valid stored document so normalization, not decoder fallback, is tested.
  var stored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  var hidden = try #require(stored["global"] as? [String: Any])
  hidden["showDirection"] = false
  hidden["showDegrees"] = false
  hidden["minorTicks"] = MinorTicks.eight.rawValue
  stored["global"] = hidden
  stored["activity"] = hidden
  let normalized = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: stored))
  #expect(normalized.global.hasReadout)
  #expect(normalized.effective(for: .activity).hasReadout)
  #expect(normalized.global.minorTicks == .eight)
  #expect(normalized.effective(for: .activity).minorTicks == .eight)
  #expect(normalized.effective(for: .phone) == custom)
}

@Test func tickChoicesDivideEveryQuadrantWithoutDuplicatedEndpoints() {
  for choice in MinorTicks.allCases {
    let angles = choice.angles
    #expect(angles.count == 4 * (choice.rawValue + 1))
    #expect(Set(angles).count == angles.count)
    #expect(angles.filter { $0.truncatingRemainder(dividingBy: 90) == 0 } == [0, 90, 180, 270])
    #expect(angles.allSatisfy { (0..<360).contains($0) })
  }
}

@Test func readoutSizesExtendToAccessibilityCategoriesWithStableStorage() throws {
  // The accessibility categories follow the standard ones in order, and the boundary between
  // them is the largest standard category.
  let sizes = ReadoutTextSize.allCases
  #expect(sizes.map(\.rawValue) == sizes.map(\.rawValue).sorted())
  #expect(sizes.first == .xSmall)
  #expect(sizes.last == .accessibility5)
  let accessibilitySizes = sizes.drop(while: { !$0.isAccessibilitySize })
  #expect(accessibilitySizes.allSatisfy { $0.isAccessibilitySize })
  #expect(accessibilitySizes.first == .accessibility1)
  #expect(!ReadoutTextSize.xxxLarge.isAccessibilitySize)
  #expect(ReadoutTextSize.accessibility1.isAccessibilitySize)
  // A size saved before the accessibility categories existed keeps its meaning. The stored
  // value 6 is the historical wire value for Extra Extra Extra Large, written here
  // independently of the current encoder so a shift in raw values would be caught.
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.useSystemTextSize = false
  preferences.setGlobal(global)
  var stored = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
  var earlier = try #require(stored["global"] as? [String: Any])
  earlier["customTextSize"] = 6
  stored["global"] = earlier
  let legacy = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: stored))
  #expect(legacy.global.customTextSize == .xxxLarge)
  #expect(!legacy.global.useSystemTextSize)
  // The largest accessibility size has its own stable stored value.
  earlier["customTextSize"] = 11
  stored["global"] = earlier
  let largest = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: stored))
  #expect(largest.global.customTextSize == .accessibility5)
  global.customTextSize = .accessibility5
  preferences.setGlobal(global)
  #expect(AppearancePreferences.decode(try JSONEncoder().encode(preferences)) == preferences)
}

@Test func reducedMotionChoiceDefaultsForAppearancesSavedWithoutIt() throws {
  // A document saved before the field existed decodes with the standard choice and keeps
  // every other stored value.
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.showDegrees = false
  global.minorTicks = .eight
  global.labels = .outside
  global.rotation = .arrow
  preferences.setGlobal(global)
  var stored = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
  var earlier = try #require(stored["global"] as? [String: Any])
  #expect(earlier.removeValue(forKey: "reducedMotionDial") != nil)
  stored["global"] = earlier
  let decoded = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: stored))
  #expect(decoded.global.reducedMotionDial == .steadyReadout)
  #expect(decoded == preferences)
  // Any key an earlier version did not store falls back to the standard choice.
  stored["global"] = [String: Any]()
  let sparse = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: stored))
  #expect(sparse == AppearancePreferences())
  global.reducedMotionDial = .rotatingDial
  preferences.setGlobal(global)
  let restored = AppearancePreferences.decode(try JSONEncoder().encode(preferences))
  #expect(restored.global.reducedMotionDial == .rotatingDial)
  #expect(restored == preferences)
}

@Test func readoutSizeChoiceFollowsGlobalsUntilSurfaceOverrides() throws {
  var preferences = AppearancePreferences()
  var global = preferences.global
  global.useSystemTextSize = false
  global.customTextSize = .xxxLarge
  preferences.setGlobal(global)
  preferences.setUsesGlobal(false, for: .phone)
  global.useSystemTextSize = true
  preferences.setGlobal(global)
  #expect(preferences.effective(for: .activity).useSystemTextSize)
  #expect(!preferences.effective(for: .phone).useSystemTextSize)
  #expect(preferences.effective(for: .phone).customTextSize == .xxxLarge)
  preferences.setUsesGlobal(true, for: .phone)
  #expect(preferences.effective(for: .phone).useSystemTextSize)
  let restored = AppearancePreferences.decode(try JSONEncoder().encode(preferences))
  #expect(restored == preferences)
}

@Test func retiredWidgetPreferencesDoNotResetOtherSurfacesOrRemainInSettings() throws {
  var preferences = AppearancePreferences()
  var phone = preferences.global
  phone.rotation = .arrow
  preferences.setOverride(phone, for: .phone)
  var activity = preferences.global
  activity.showDegrees = false
  preferences.setOverride(activity, for: .activity)
  let encoded = try JSONEncoder().encode(preferences)
  var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  legacy["widget"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(phone))
  let decoded = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: legacy))
  #expect(decoded.effective(for: .phone) == phone)
  #expect(decoded.effective(for: .activity) == activity)
  #expect(!AppearanceSurface.allCases.contains { $0.rawValue == "widget" })
  let saved = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
  #expect(saved["widget"] == nil)
}

@Test func appThemeDefaultsToSystemWithoutResettingSavedAppearances() throws {
  #expect(AppearancePreferences().theme == .system)
  let legacy = Data(
    #"{"global":{"showDegrees":false},"phone":{"rotation":"arrow"},"activity":{"labels":"outside"}}"#
      .utf8)
  let decoded = AppearancePreferences.decode(legacy)
  #expect(decoded.theme == .system)
  #expect(!decoded.global.showDegrees)
  #expect(decoded.effective(for: .phone).rotation == .arrow)
  #expect(decoded.effective(for: .activity).labels == .outside)
  var stored = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
  stored["theme"] = "unsupported-future-theme"
  let unknown = AppearancePreferences.decode(try JSONSerialization.data(withJSONObject: stored))
  #expect(unknown == decoded)
}

@Test func appThemeRoundTripsIndependentlyOfSurfaceOverrides() throws {
  for theme in AppTheme.allCases {
    var preferences = AppearancePreferences()
    var phone = preferences.global
    phone.rotation = .arrow
    preferences.setOverride(phone, for: .phone)
    let activity = preferences.effective(for: .activity)
    preferences.theme = theme
    let restored = AppearancePreferences.decode(try JSONEncoder().encode(preferences))
    #expect(restored.theme == theme)
    #expect(restored.effective(for: .phone) == phone)
    #expect(restored.effective(for: .activity) == activity)
  }
}
