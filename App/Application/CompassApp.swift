import CompassCore
import SwiftUI
import UIKit

@main
struct CompassApp: App {
  @UIApplicationDelegateAdaptor(CompassAppDelegate.self) private var appDelegate
  var body: some Scene {
    WindowGroup {
      CompassView(drive: appDelegate.drive)
        .modifier(AppThemeModifier(store: .shared))
    }
  }
}

/// Applies the preference to this app presentation only, including its Settings navigation.
struct AppThemeModifier: ViewModifier {
  @ObservedObject var store: AppearanceStore

  func body(content: Content) -> some View {
    content.preferredColorScheme(store.preferences.theme.colorScheme)
  }
}

extension AppTheme {
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
