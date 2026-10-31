import CompassCore
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Compass

@Suite @MainActor
struct AppearanceStoreTests {
  @Test func savesOverridesAndPreservesUnchangedPreferences() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    store.update { preferences in
      var activity = preferences.effective(for: .activity)
      activity.showDegrees = false
      preferences.setOverride(activity, for: .activity)
    }
    #expect(!AppearanceStore.read(from: defaults).effective(for: .activity).showDegrees)
    let saved = store.preferences
    store.update { _ in }
    #expect(store.preferences == saved)
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(reopened.preferences == saved)
  }

  @Test func appThemePersistsAndUpdatesTheAppAndSettingsPresentation() async throws {
    let name = "theme-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(store.preferences.theme == .system)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.overrideUserInterfaceStyle = .dark
    var observed: [String: ColorScheme] = [:]
    let host = UIHostingController(
      rootView:
        ZStack {
          ThemeProbe { observed["compass"] = $0 }
          NavigationStack {
            Form { ThemeProbe { observed["settings"] = $0 } }
          }
        }
        .modifier(AppThemeModifier(store: store)))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    for (theme, expected) in [
      (AppTheme.dark, ColorScheme.dark), (.light, .light), (.system, .dark),
    ] {
      store.update { $0.theme = theme }
      let deadline = ContinuousClock.now + .seconds(3)
      while (observed["compass"] != expected || observed["settings"] != expected),
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(observed["compass"] == expected)
      #expect(observed["settings"] == expected)
      #expect(
        AppearanceStore(defaults: defaults, legacyDefaults: defaults).preferences.theme == theme)
    }
    // System must release the override, including subsequent host appearance changes.
    window.overrideUserInterfaceStyle = .light
    let deadline = ContinuousClock.now + .seconds(3)
    while (observed["compass"] != .light || observed["settings"] != .light),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(observed["compass"] == .light)
    #expect(observed["settings"] == .light)
  }

  @Test func everyReadoutSizeMapsToItsDynamicTypeCategoryInOrder() {
    // Choosing a larger custom size must render larger, and the accessibility boundary the
    // slider shows must be the one the system applies.
    let mapped = ReadoutTextSize.allCases.map(\.dynamicTypeSize)
    #expect(mapped == mapped.sorted())
    #expect(Set(mapped).count == mapped.count)
    #expect(ReadoutTextSize.xxxLarge.dynamicTypeSize == .xxxLarge)
    #expect(ReadoutTextSize.accessibility5.dynamicTypeSize == .accessibility5)
    #expect(
      ReadoutTextSize.allCases.allSatisfy {
        $0.isAccessibilitySize == $0.dynamicTypeSize.isAccessibilitySize
      })
    // Every slider step announces a distinct value.
    let titles = ReadoutTextSize.allCases.map(\.title)
    #expect(Set(titles).count == titles.count)
  }

  @Test func migratesOnlyExistingPhoneArrowChoiceOnce() throws {
    let name = "appearance-tests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(false, forKey: "rotatesCompassDial")
    let store = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(store.preferences.effective(for: .phone).rotation == .arrow)
    #expect(store.preferences.usesGlobal(for: .activity))
    store.update { $0.setUsesGlobal(true, for: .phone) }
    let reopened = AppearanceStore(defaults: defaults, legacyDefaults: defaults)
    #expect(reopened.preferences.usesGlobal(for: .phone))
  }
}

private struct ThemeProbe: View {
  @Environment(\.colorScheme) private var scheme
  let observed: (ColorScheme) -> Void

  var body: some View {
    Color.clear.frame(width: 1, height: 1)
      .onChange(of: scheme, initial: true) { _, value in observed(value) }
  }
}
