import CompassCore
import Testing

@Test func settingsSwipeRequiresIntentionalLeftwardMotion() {
  for (x, y) in [(0.0, 0.0), (100, 0), (-10, 100), (-100, 50), (-100, -60)] {
    var swipe = SettingsDismissalSwipe()
    let result1 = !swipe.begin(horizontal: x, vertical: y)
    #expect(result1)
    let result2 = !swipe.finish(horizontal: -100, vertical: 0)
    #expect(result2)
  }
  for (x, y) in [(-60.0, 0.0), (-59, 0), (-100, 50), (-100, -51), (100, 0)] {
    var swipe = SettingsDismissalSwipe()
    let result3 = swipe.begin(horizontal: -100, vertical: 0)
    #expect(result3)
    let result4 = !swipe.finish(horizontal: x, vertical: y)
    #expect(result4)
  }
  var swipe = SettingsDismissalSwipe()
  let result5 = swipe.begin(horizontal: -100, vertical: 1)
  #expect(result5)
  let result6 = swipe.finish(horizontal: -61, vertical: 2)
  #expect(result6)
}

@Test func cancelledAndRepeatedSettingsSwipesDoNotDismissUnexpectedly() {
  var swipe = SettingsDismissalSwipe()
  let result7 = !swipe.finish(horizontal: -100, vertical: 0)
  #expect(result7)
  let result8 = swipe.begin(horizontal: -100, vertical: 0)
  #expect(result8)
  swipe.cancel()
  let result9 = !swipe.finish(horizontal: -100, vertical: 0)
  #expect(result9)
  let result10 = swipe.begin(horizontal: -100, vertical: 0)
  #expect(result10)
  let result11 = swipe.finish(horizontal: -100, vertical: 0)
  #expect(result11)
  let result12 = !swipe.finish(horizontal: -100, vertical: 0)
  #expect(result12)
  let result13 = swipe.begin(horizontal: -100, vertical: 0)
  #expect(result13)
  let result14 = !swipe.finish(horizontal: -20, vertical: 0)
  #expect(result14)
  let result15 = swipe.begin(horizontal: -100, vertical: 0)
  #expect(result15)
  let result16 = swipe.finish(horizontal: -100, vertical: 0)
  #expect(result16)
}
