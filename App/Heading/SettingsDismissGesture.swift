import CompassCore
import SwiftUI
import UIKit

/// A right-edge gesture shared by Settings and every page in its navigation stack.
struct SettingsDismissGesture: UIGestureRecognizerRepresentable {
  let close: () -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
    let recognizer = UIScreenEdgePanGestureRecognizer()
    recognizer.edges = .right
    recognizer.cancelsTouchesInView = false
    recognizer.delaysTouchesBegan = false
    recognizer.delaysTouchesEnded = false
    recognizer.delegate = context.coordinator
    return recognizer
  }

  func handleUIGestureRecognizerAction(
    _ recognizer: UIScreenEdgePanGestureRecognizer, context: Context
  ) {
    context.coordinator.handle(recognizer, close: close)
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    private var swipe = SettingsDismissalSwipe()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer else { return false }
      let velocity = pan.velocity(in: nil)
      return swipe.begin(horizontal: velocity.x, vertical: velocity.y)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
      Self.allowsTouch(in: touch.view)
    }

    static func allowsTouch(in view: UIView?) -> Bool {
      var current = view
      while let candidate = current {
        // Leave sliders, switches, buttons and their descendants to their controls.
        if candidate is UIControl { return false }
        current = candidate.superview
      }
      return true
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    func handle(_ recognizer: UIScreenEdgePanGestureRecognizer, close: () -> Void) {
      switch recognizer.state {
      case .ended:
        let translation = recognizer.translation(in: nil)
        if swipe.finish(horizontal: translation.x, vertical: translation.y) { close() }
      case .cancelled, .failed: swipe.cancel()
      default: break
      }
    }
  }
}
