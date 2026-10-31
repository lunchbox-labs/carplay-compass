import Testing
import UIKit
@testable import Compass

@Suite @MainActor
struct SettingsDismissGestureTests {
  @Test func leavesInteractiveControlsAndTheirChildrenAlone() {
    for control in [UISlider(), UISwitch(), UIButton()] as [UIControl] {
      let child = UIView()
      control.addSubview(child)
      #expect(!SettingsDismissGesture.Coordinator.allowsTouch(in: control))
      #expect(!SettingsDismissGesture.Coordinator.allowsTouch(in: child))
    }
    #expect(SettingsDismissGesture.Coordinator.allowsTouch(in: UIView()))
  }

  @Test func rejectsVerticalScrollAndRightwardBackMotionBeforeRecognition() {
    let coordinator = SettingsDismissGesture.Coordinator()
    let pan = TestEdgePan()
    for velocity in [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 100), .zero] {
      pan.movement = velocity
      #expect(!coordinator.gestureRecognizerShouldBegin(pan))
    }
    pan.movement = CGPoint(x: -100, y: 5)
    #expect(coordinator.gestureRecognizerShouldBegin(pan))
    // Nested navigation's left-edge Back and Form scrolling may keep recognizing.
    let navigation = UINavigationController(rootViewController: UIViewController())
    navigation.pushViewController(UIViewController(), animated: false)
    let back = navigation.interactivePopGestureRecognizer ?? UIPanGestureRecognizer()
    #expect(coordinator.gestureRecognizer(pan, shouldRecognizeSimultaneouslyWith: back))
    #expect(
      coordinator.gestureRecognizer(
        pan, shouldRecognizeSimultaneouslyWith: UIScrollView().panGestureRecognizer))
  }

  @Test func onlyCompletedSwipeCallsCloseOnceAndCancellationCanBeRetried() {
    let coordinator = SettingsDismissGesture.Coordinator()
    let pan = TestEdgePan()
    var closures = 0
    let close = { closures += 1 }
    pan.movement = CGPoint(x: -100, y: 0)
    #expect(coordinator.gestureRecognizerShouldBegin(pan))
    pan.phase = .changed
    coordinator.handle(pan, close: close)
    #expect(closures == 0)
    pan.phase = .cancelled
    coordinator.handle(pan, close: close)
    pan.phase = .ended
    coordinator.handle(pan, close: close)
    #expect(closures == 0)
    #expect(coordinator.gestureRecognizerShouldBegin(pan))
    coordinator.handle(pan, close: close)
    coordinator.handle(pan, close: close)
    #expect(closures == 1)
    #expect(coordinator.gestureRecognizerShouldBegin(pan))
    coordinator.handle(pan, close: close)
    #expect(closures == 2)
  }
}

@MainActor
private final class TestEdgePan: UIScreenEdgePanGestureRecognizer {
  var phase: UIGestureRecognizer.State = .possible
  var movement: CGPoint = .zero
  override var state: UIGestureRecognizer.State {
    get { phase }
    set { phase = newValue }
  }
  override func velocity(in view: UIView?) -> CGPoint { movement }
  override func translation(in view: UIView?) -> CGPoint { movement }
}
