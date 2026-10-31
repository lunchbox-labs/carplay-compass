# Compasslet

A native SwiftUI **iOS 27+ iPhone compass** showing the direction the top of your
phone points relative to magnetic north. The phone compass works while stationary;
nearby magnets and metal can affect its accuracy. CarPlay separately displays the
vehicle’s direction of travel relative to true north, using precise location only
during an active drive. Travel direction includes reverse movement and does not
represent the direction the vehicle’s nose points.

## Run the app

Open `Compass.xcodeproj` in **Xcode 27.1** and choose the shared **Compass** scheme.
Select an iPhone simulator or your iPhone, then Run. For a physical device, select
your own development team in Signing & Capabilities; no team or credentials are
checked into this project. The interface supports portrait orientation.

Simulator has no heading sensor and displays an unavailable explanation. Use an
actual iPhone for live compass readings. The app removes invalid readings and
readings older than five seconds, and pauses when it leaves the foreground.
Magnetic heading does not require requesting raw location or true north.

From macOS with Xcode 27.1 selected:

```sh
xcodebuild -project Compass.xcodeproj -scheme Compass \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
bash scripts/test-ios
```

The test script chooses an installed, available iOS 27+ iPhone simulator. It runs
hosted state tests using injected sensor events and time; it does not fabricate
production sensor readings. CI builds the actual app and runs this shared scheme.

On a physical iPhone, check that the first foreground opening requests When In Use
location once, that the heading follows the phone’s top while stationary, and that
crossing north does not spin the dial or arrow around. Check both display styles
in Settings, calibration away from metal and
magnets, leaving and returning to the foreground, and recovery after an
interruption. Check actual denied/restricted service behavior if system settings
produce it; an undetermined location authorization alone does not block magnetic
heading. Also check VoiceOver, larger Dynamic Type (including the AX3 and AX5
accessibility sizes with Bold Text on the smallest supported iPhone, where the
compass screen keeps one whole reading and leaves details to Settings), light/dark
appearance, and Reduce Motion. With Reduce Motion on, the phone shows a steady text
reading that follows the sensor instead of the rotating dial, unless Appearance keeps
the dial; the dial then moves in steps of about four degrees rather than continuously,
so a settled reading can differ from the sensor by up to four degrees. Device sensor
accuracy and these physical-device checks remain separate from simulator state tests.

## Set up CarPlay

While parked, open Compasslet on iPhone and allow the initial When In Use request
with Precise Location. The app’s **Settings** menu shows location status and an
**Open Settings** action where permission needs repair. Granting access does not
start travel collection. Then open Compasslet from the CarPlay launcher to start a
drive automatically; no phone Start Drive action is needed. Connecting a cable
alone does not guarantee app launch. Setup and permission repair happen on iPhone
while parked. Never grant Always authorization for this feature.

The full-screen readout uses Apple’s native list details header with a compass
thumbnail, an explicitly **Sampled** course, **Travel · True north**, the original
sample time, and status. The thumbnail is drawn at the car display’s own scale and
style. It is a snapshot rather than a continuously live compass.
New snapshots appear at most once every ten seconds. Fresh sensor input keeps the
previous snapshot visible between updates without changing its timestamp. Missing,
unreliable or older-than-five-second sensor input immediately removes the numeric
bearing and arrow. While the app is rendering, the ten-second update interval and
five-second input freshness limit bound the displayed sample’s age to fifteen
seconds; the app does not retain the last reading after acquisition fails.
There are no manual drive
controls on iPhone or CarPlay. Switching to Maps keeps the drive running with the background
location indicator. A CarPlay template scene disconnect, lost permission, Location
Services being turned off, or an eight-hour limit stops acquisition. Dismissing the Live Activity on iPhone, or iOS
ending it, only removes the compact display for the rest of that drive. Reopen the
CarPlay app after leaving it to start a new drive. An ordinary phone launch never resumes a drive. On the full-screen template, slow
movement, poor measurements, and data older than five seconds remove the bearing.

The compact Dashboard surface uses a Live Activity showing **Last travel** and the
original sample time. A stopped car, missing newer course or temporary poor course
quality keeps the last accepted direction within the same active drive. It is a
recorded travel direction, not a measurement of where a stationary car points.
New course samples must still pass the five-second input check. Unchanged displayed
readings need no heartbeat updates; changed readings are limited to once a second.
An explicit location interruption clears the activity reading; drive teardown,
permission/service loss and the eight-hour limit clear and end the activity.
Dismissing the activity does not stop the CarPlay drive. iOS controls activity
lifecycle and rendering. No prior-drive reading is restored.
Only bearing/status/sample time reaches ActivityKit. No route history or backend
is added. Physical-device checks must verify the retained sample label, stop and
recovery behavior, and clearing on teardown. This activity policy does not change
the phone compass or full-screen CarPlay freshness rules.

The checked-in driving-task entitlement is a declaration only. Full-screen
CarPlay on a physical device requires Apple’s approval and matching signing and
provisioning, supplied externally. There is no navigation entitlement. Unsigned
Simulator builds remain the normal compilation check; they do not prove category
approval or in-car operation.

Before release, validate an entitled iPhone and CarPlay system with the phone
locked, Maps visible, actual disconnect, stopping/reversing, poor GPS, denied and
reduced-precision permission, Live Activities disabled/dismissed, accessibility,
and thermal/battery behavior. CarPlay-only ActivityKit startup with a locked phone
and foreground eligibility for starting background acquisition are physical gates.
Validate that retained compact readings keep their sample time, recover on a new
valid course, and clear on explicit acquisition failure or teardown. A changed
reading is pushed at most once per second; unchanged readings need no heartbeat.
iOS does not guarantee rendering cadence.

Ordinary Home Screen, Lock Screen and CarPlay timeline widgets are not included.
The Live Activity uses the retained WidgetKit extension with ActivityKit updates,
not timeline refresh requests. Existing widget placements should be removed.

## Debug diagnostics

Settings › Diagnostics shows Export Diagnostics and Clear Logs only while Debug
Mode is on. Turning Debug Mode off stops collection and clears stored logs and
active timing clocks in one transaction. Clear Logs erases the current recording
without switching Debug Mode off. Enabling Debug Mode does not erase an existing
recording. Exporting creates a temporary JSON file for the share sheet, removed
when the sheet closes; copies saved or shared elsewhere are outside the app's
control.

Diagnostics contain local timing events for the Live Activity and full-screen
CarPlay, not coordinates or bearings. Each display retains up to 30 observed
active-feed minutes with a 50,000-event cap. Timing records do not establish screen
visibility or refresh rate. Delayed asynchronous completions are accepted only
for the recording session in which their work started, so disabling or clearing
logs cannot restore records from that session.

## Swift style

Use **Swift 6.4.1**, including its bundled **swift-format 6.4.1**, on Linux.
Install the toolchain from [Swift.org](https://www.swift.org/install/), and make
`swift-format` available on `PATH`. The script checks its exact version. This
patch is a Linux release; Xcode 27.1 provides Swift 6.4 for the native app.
On macOS, optionally run the pinned formatter with Docker:

```sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.4.1 bash scripts/swift-style check
```

Xcode build and Run do not require Docker.

From the repository root:

```sh
bash scripts/swift-style check
bash scripts/swift-style format
```

`check` reports formatting and lint findings as errors. `format` rewrites Swift
files; run `check` afterward because formatting cannot fix every lint finding.
Both commands include tracked Swift files and nonignored untracked Swift files,
exclude symbolic links, and return status 2 when there are no Swift files to
process. Keep generated output and vendored sources untracked and ignored.

The configuration follows the [Swift profile in KrishRVH/standards](https://github.com/KrishRVH/standards/tree/main/Swift):
two-space indentation, a 100-column target, documentation checks, and diagnostics
for force unwraps, force tries, and implicitly unwrapped optionals. Native rule
exceptions still apply. SwiftLint is not required.

## Portable core

CompassCore is a dependency-free Swift package using Swift 6 language mode,
warnings as errors, and Swift Testing. On Linux with Swift 6.4.1, run
`swift build --jobs 4 -c release` and `swift test --jobs 4`.
Apple UI and CoreLocation compilation require macOS and Xcode; formatting and
Linux syntax checks do not validate Apple SDK integration.

## CompassCore usage

`CompassAngle(degrees:)` normalizes finite angles into `0..<360`. Its
`shortestDelta(to:)` returns the signed shortest rotation, with exact half-turns
always represented by +180 degrees.

`CompassSample(degrees:source:reference:accuracy:timestamp:)` accepts sensor angles
in `0...360`, nonnegative finite accuracy, and finite timestamps. Negative sensor
sentinels are rejected. Use `.deviceHeading` for device orientation and
`.vehicleCourse` for direction of travel; north references are `.magnetic` and
`.trueNorth`. A zero-degree reading is valid.

Call `isFresh(now:maximumAge:)` with an injected clock and finite nonnegative age
limit. The age boundary is inclusive; future readings are rejected.
`CompassSmoother(fraction:fullTrackingDelta:)` accepts a fraction in `(0, 1]` and an
optional positive rotation size in degrees at which a new reading is adopted outright;
smaller rotations interpolate by at least the fraction. Pass validated samples
to `update(_:now:maximumAge:)`; pass nil when a sensor reading is invalid. The
smoother crosses north by the shortest rotation and preserves the latest sample's
metadata. `TravelCourseFilter` uses a 0.25 fraction with full tracking at 20
degrees. Missing/stale input clears its state. Changes in source or north
reference, stale gaps, and reversed timestamps start a new sequence. Use `reset()`
when ending a sensor session.
