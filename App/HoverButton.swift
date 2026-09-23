import AppKit

/// Gives ordinary AppKit push buttons clear hover and press feedback without
/// replacing their native macOS appearance.
class HoverButton: NSButton {
  var isInteractionAvailable = true {
    didSet {
      updateFeedback(animated: false)
      window?.invalidateCursorRects(for: self)
    }
  }

  var disabledAlphaValue: CGFloat = 0.55 {
    didSet {
      updateFeedback(animated: false)
    }
  }

  private var hoverTrackingArea: NSTrackingArea?
  private var pointerIsInside = false
  private var pointerIsPressed = false

  override var isEnabled: Bool {
    didSet {
      updateFeedback(animated: false)
      window?.invalidateCursorRects(for: self)
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    prepareFeedback()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    prepareFeedback()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseEnteredAndExited,
        .activeInKeyWindow,
        .inVisibleRect,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    hoverTrackingArea = trackingArea
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard isEnabled, isInteractionAvailable else { return }
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    pointerIsInside = true
    updateFeedback(animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    pointerIsInside = false
    updateFeedback(animated: true)
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, isInteractionAvailable else {
      return
    }
    pointerIsPressed = true
    updateFeedback(animated: true)
    super.mouseDown(with: event)
    pointerIsPressed = false
    updateFeedback(animated: true)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateFeedback(animated: false)
  }

  private func prepareFeedback() {
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = false
    updateFeedback(animated: false)
  }

  private func updateFeedback(animated: Bool) {
    let changes = {
      if !self.isEnabled || !self.isInteractionAvailable {
        self.alphaValue = self.disabledAlphaValue
        self.layer?.shadowOpacity = 0
      } else if self.pointerIsPressed {
        self.alphaValue = 0.78
        self.layer?.shadowOpacity = 0.08
      } else if self.pointerIsInside {
        self.alphaValue = 1
        self.layer?.shadowOpacity = 0.24
      } else {
        self.alphaValue = 1
        self.layer?.shadowOpacity = 0
      }
      self.layer?.shadowColor = NSColor.controlAccentColor.cgColor
      self.layer?.shadowRadius = self.pointerIsPressed ? 2 : 5
      self.layer?.shadowOffset = .zero
    }

    guard
      animated,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      changes()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.09
      context.allowsImplicitAnimation = true
      changes()
    }
  }
}
