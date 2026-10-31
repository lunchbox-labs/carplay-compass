import SwiftUI
import UIKit

struct CompassSettingsView: View {
  @ObservedObject var drive: DriveSessionController
  @ObservedObject var location: PhoneLocationController
  let headingStatus: HeadingController.Status
  var showLocationDetails = false
  let close: () -> Void
  @State private var locationDetailsPresented = false
  @AccessibilityFocusState private var closeFocused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section("Display") {
          NavigationLink("Appearance") { AppearanceSettingsView() }
          NavigationLink("Accessibility") { AccessibilitySettingsView(close: close) }
        }
        Section("Location") {
          NavigationLink("Location Details") { locationDetails }
          LabeledContent("Location Enabled", value: locationEnabled ? "Yes" : "No")
          Text(locationDetail).foregroundStyle(.secondary)
          if canOpenSettings, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: url)
          }
        }
        Section("Apple Watch") {
          Label("Experimental Support", systemImage: "applewatch")
          Text(
            "Apple Watch runtime and device validation are incomplete. Support is experimental and may not work as expected."
          )
          .foregroundStyle(.secondary)
        }
        DiagnosticsSettingsSection()
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $locationDetailsPresented) { locationDetails }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: close)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityFocused($closeFocused)
        }
      }
    }
    .task {
      locationDetailsPresented = showLocationDetails
      closeFocused = true
    }
  }

  private var locationDetails: some View {
    Form {
      Section("Current Location") {
        PhoneLocationReadout(location: location)
      }
      if headingStatus != .live {
        Section(headingStatus.title) {
          Text(headingStatus.detail)
          if headingStatus == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Open Settings", destination: url)
          }
        }
      }
    }
    .navigationTitle("Location Details")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: close).frame(minWidth: 44, minHeight: 44)
      }
    }
  }

  private var locationEnabled: Bool {
    drive.setupStatus == .ready || drive.setupStatus == .preciseLocationRequired
  }

  private var canOpenSettings: Bool {
    switch drive.setupStatus {
    case .denied, .servicesDisabled, .preciseLocationRequired: true
    case .ready, .permissionRequired, .restricted, .unavailable: false
    }
  }

  private var locationDetail: String {
    switch drive.setupStatus {
    case .ready:
      "Precise location is enabled for phone coordinates, elevation, and CarPlay travel direction."
    case .permissionRequired: "Location permission has not been granted yet."
    case .denied:
      "Allow location while using the app for phone location details and CarPlay travel direction."
    case .restricted: "Location access is restricted by this device’s settings or management."
    case .servicesDisabled:
      "Location Services is off. Turn it on in iPhone Settings under Privacy & Security."
    case .preciseLocationRequired:
      "Location is allowed, but CarPlay travel direction needs Precise Location."
    case .unavailable: "Travel direction is unavailable on this device."
    }
  }
}

struct PhoneLocationReadout: View {
  @ObservedObject var location: PhoneLocationController

  var body: some View {
    VStack(spacing: 8) {
      if let fix = location.location {
        let latitude = Self.coordinate(fix.coordinate.latitude, latitude: true)
        let longitude = Self.coordinate(fix.coordinate.longitude, latitude: false)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) {
            coordinateText(latitude)
            coordinateText(longitude)
          }
          .fixedSize(horizontal: true, vertical: true)
          VStack(spacing: 4) {
            coordinateText(latitude)
            coordinateText(longitude)
          }
        }
        .font(.subheadline).monospacedDigit()
        if let city = location.city {
          Text(city)
        }
        if let elevation = location.elevation {
          Text("\(Self.formattedElevation(elevation)) Elevation")
            .accessibilityLabel("Elevation \(Self.formattedElevation(elevation, spoken: true))")
        } else {
          Text("Elevation unavailable").foregroundStyle(.secondary)
        }
      } else {
        Text(location.approximate ? "Approximate location" : "Location unavailable")
          .foregroundStyle(.secondary)
      }
    }
  }

  /// A coordinate component in its visual notation and in words for assistive technologies.
  struct Coordinate {
    let visual: String
    let spoken: String
  }

  private func coordinateText(_ coordinate: Coordinate) -> some View {
    Text(coordinate.visual).accessibilityLabel(coordinate.spoken)
  }

  /// Degrees, minutes and seconds with a hemisphere letter, plus the same value spoken in full.
  static func coordinate(_ degrees: Double, latitude: Bool) -> Coordinate {
    let totalSeconds = Int((abs(degrees) * 3600).rounded())
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(
      .never)
    let d = totalSeconds / 3600
    let m = totalSeconds / 60 % 60
    let s = totalSeconds % 60
    let hemisphere =
      latitude
      ? (degrees < 0 ? String(localized: "S") : String(localized: "N"))
      : (degrees < 0 ? String(localized: "W") : String(localized: "E"))
    let hemisphereName =
      latitude ? (degrees < 0 ? "south" : "north") : (degrees < 0 ? "west" : "east")
    let spokenParts = [
      latitude ? "Latitude" : "Longitude",
      "\(d) \(d == 1 ? "degree" : "degrees")",
      "\(m) \(m == 1 ? "minute" : "minutes")",
      "\(s) \(s == 1 ? "second" : "seconds")",
      hemisphereName,
    ]
    return Coordinate(
      visual:
        "\(Double(d).formatted(style))°\(Double(m).formatted(style))′\(Double(s).formatted(style))″ \(hemisphere)",
      spoken: spokenParts.joined(separator: " "))
  }

  /// Rounded elevation in the locale's unit; the spoken form names the unit in full.
  static func formattedElevation(_ meters: Double, spoken: Bool = false) -> String {
    let unit: UnitLength = Locale.current.measurementSystem == .us ? .feet : .meters
    let value = Measurement(value: meters, unit: UnitLength.meters).converted(to: unit)
    let formatter = MeasurementFormatter()
    formatter.unitOptions = .providedUnit
    formatter.unitStyle = spoken ? .long : .medium
    formatter.numberFormatter.maximumFractionDigits = 0
    return formatter.string(from: value)
  }
}
