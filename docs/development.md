# Development

Open `Compass.xcodeproj` in Xcode 27.1 and choose the Compass scheme. Use your own
signing team for a physical device. Simulator has no heading sensor; use an iPhone
to verify real readings. The interface supports portrait orientation.

## Checks

On macOS with Xcode 27.1 selected:

```sh
xcodebuild -project Compass.xcodeproj -scheme Compass \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
bash scripts/test-ios
bash scripts/test-watch
```

The test script selects an available iOS 27+ iPhone simulator. Hosted tests inject
sensor events and time; they do not validate physical sensors or CarPlay operation.
Watch tests require an available watchOS 27+ simulator paired with an available
iPhone simulator. Watch runtime and physical-device validation remain incomplete;
keep its Experimental designation until those gaps are resolved.

On Linux, use Swift 6.4.1 and its bundled swift-format 6.4.1:

```sh
bash scripts/swift-style check
swift build --jobs 4 -c release
swift test --jobs 4
```

Use `bash scripts/swift-style format` to apply formatting, then run `check` again.
The formatter includes tracked and nonignored untracked Swift files, excluding
symlinks. Generated and vendored output should remain ignored. Xcode uses Swift
6.4; Apple SDK integration still requires native checks.

With the metadata sync tooling installed, run its offline checks with Python 3
and OpenSSL; no Apple credentials or network access are needed:

```sh
python3 -m unittest discover -s scripts/tests -v
```

## Device validation

Before release, verify stationary phone heading, crossing north, both display
styles, foreground recovery and unavailable-sensor behavior. Check VoiceOver,
large Dynamic Type with Bold Text on the smallest supported iPhone, contrast,
light/dark appearance and Reduce Motion. Reduce Motion normally replaces the dial
with text; Keep the Dial uses discrete steps rather than continuous rotation.

CarPlay requires Apple's driving-task approval and matching external provisioning;
the checked-in entitlement and unsigned builds do not establish approval. Validate
an entitled iPhone and car while parked, including locked-phone startup, switching
to Maps, disconnect, stopped/reverse travel, poor GPS, permission/precision loss,
Live Activity dismissal, accessibility and battery/thermal behavior. Confirm that
retained activity samples preserve their time and clear on interruption or teardown.
iOS controls rendering; simulator success cannot establish in-car update cadence.

## Reading policies

Phone magnetic headings expire after five seconds and acquisition pauses outside
the foreground. Full-screen CarPlay samples update at most every ten seconds;
invalid or older-than-five-second input clears the bearing. Reverse travel is
travel direction, not vehicle orientation.

The Live Activity retains the last valid travel sample through stops within the
same drive. Explicit interruption clears it; disconnect, permission/service loss
or the eight-hour limit clears and ends it. Dismissal removes only the activity
for that drive. Changed readings update at most once per second; unchanged readings
need no heartbeat. No prior-drive reading is restored.

## CompassCore

CompassCore contains angle normalization, sample validation, freshness checks and
shortest-path smoothing. Keep device heading and vehicle course sources distinct,
and preserve their magnetic/true-north references and original timestamps.
Invalid input or a stale gap must not be presented as a new reading. See the public
API documentation and behavioral tests in `Sources` and `Tests` when changing these
contracts.

Release maintainers use [Publishing](publishing.md).
