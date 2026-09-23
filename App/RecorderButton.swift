import AppKit
import Carbon

final class RecorderButton: HoverButton {
  var onRecord: ((UInt32, UInt32, String) -> Bool)?
  var onRecordingStateChanged: ((Bool) -> Void)?
  var onValidationMessage: ((String) -> Void)?

  private var isRecordingShortcut = false
  private var previousTitle = ""
  private var keyMonitor: Any?

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    beginRecording()
  }

  override func performClick(_ sender: Any?) {
    beginRecording()
  }

  override func accessibilityPerformPress() -> Bool {
    beginRecording()
    return true
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      cancelRecording()
    }
    return result
  }

  override func keyDown(with event: NSEvent) {
    guard isRecordingShortcut else {
      super.keyDown(with: event)
      return
    }
    recordShortcut(from: event)
  }

  private func beginRecording() {
    guard !isRecordingShortcut else { return }
    isRecordingShortcut = true
    previousTitle = title
    title = "Press shortcut…"
    onRecordingStateChanged?(true)
    window?.makeFirstResponder(self)
    startKeyMonitor()
  }

  private func recordShortcut(from event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      cancelRecording()
      return
    }

    let relevantFlags = event.modifierFlags.intersection([
      .command, .shift, .option, .control,
    ])
    let modifiers = carbonModifiers(from: relevantFlags)
    if let message = shortcutValidationMessage(
      keyCode: UInt32(event.keyCode),
      modifiers: modifiers
    ) {
      onValidationMessage?(message)
      return
    }

    let display =
      "\(displayModifiers(from: relevantFlags))+\(keyName(for: event))"
    isRecordingShortcut = false
    stopKeyMonitor()

    if onRecord?(UInt32(event.keyCode), modifiers, display) == true {
      title = display
      previousTitle = display
    } else {
      title = previousTitle
    }
    onRecordingStateChanged?(false)
  }

  private func startKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { [weak self] event in
      guard let self,
        self.isRecordingShortcut,
        self.window?.isKeyWindow == true
      else {
        return event
      }
      self.recordShortcut(from: event)
      return nil
    }
  }

  private func stopKeyMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }

  private func cancelRecording() {
    guard isRecordingShortcut else { return }
    isRecordingShortcut = false
    stopKeyMonitor()
    title = previousTitle
    onRecordingStateChanged?(false)
    onValidationMessage?("Shortcut change cancelled.")
  }

  deinit {
    stopKeyMonitor()
  }
}
