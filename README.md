# Compasslet

See your direction on iPhone and while driving with CarPlay.

- A phone compass that works while stationary, with dial and text displays.
- A CarPlay app showing sampled travel direction.
- A compact Live Activity that keeps your last travel direction and sample time
  visible through stops, updating when a new valid reading arrives.
- Support for VoiceOver, larger text and Reduce Motion.

Requires iOS 27 or later. The phone compass points relative to magnetic north;
nearby magnets and metal can affect accuracy. CarPlay shows travel relative to
true north, including reverse movement, rather than where a stationary car points.
CarPlay readings are sampled; iOS controls when the Live Activity is displayed.
Ordinary Home Screen and Lock Screen widgets are not included.

Apple Watch support is experimental: runtime and device validation are incomplete,
and it may not work as expected.

## Using CarPlay

While parked, open Compasslet on iPhone and allow While Using location access with
Precise Location. Use Settings to repair permissions if needed; Always access is
not required. Open Compasslet from the CarPlay launcher to start automatically.
Connecting a cable alone may not launch the app.

Switching to Maps keeps the drive running with the background location indicator.
Disconnecting the CarPlay app scene, losing location access, or reaching the
eight-hour limit ends collection. Dismissing the Live Activity removes the compact
display without stopping the drive. Reopen the CarPlay app after leaving it to
start a new drive.

## Contributing

See the [development guide](docs/development.md) for building and validating the app.
