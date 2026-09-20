import AppKit
import Carbon

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
  var result: UInt32 = 0
  if flags.contains(.command) { result |= UInt32(cmdKey) }
  if flags.contains(.shift) { result |= UInt32(shiftKey) }
  if flags.contains(.option) { result |= UInt32(optionKey) }
  if flags.contains(.control) { result |= UInt32(controlKey) }
  return result
}

func displayModifiers(from flags: NSEvent.ModifierFlags) -> String {
  var parts: [String] = []
  if flags.contains(.command) { parts.append("Cmd") }
  if flags.contains(.shift) { parts.append("Shift") }
  if flags.contains(.option) { parts.append("Option") }
  if flags.contains(.control) { parts.append("Ctrl") }
  return parts.joined(separator: "+")
}

func shortcutValidationMessage(
  keyCode: UInt32,
  modifiers: UInt32
) -> String? {
  let allowed =
    UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey)
    | UInt32(controlKey)

  guard modifiers != 0, modifiers & ~allowed == 0 else {
    return "Add Command, Shift, Option, or Control."
  }
  guard keyCode <= UInt32(UInt16.max) else {
    return "That key can't be used. Choose another one."
  }
  if keyCode == UInt32(kVK_ANSI_Q), modifiers == UInt32(cmdKey) {
    return "Choose a shortcut other than Command-Q."
  }
  return nil
}

func keyName(for event: NSEvent) -> String {
  if event.keyCode == UInt16(kVK_Space) {
    return "Space"
  }
  if let value = event.charactersIgnoringModifiers, !value.isEmpty {
    return value.uppercased()
  }
  return "Key \(event.keyCode)"
}

struct StoredShortcut {
  let keyCode: UInt32
  let modifiers: UInt32
  let display: String
}

func storedShortcut(in defaults: UserDefaults) -> StoredShortcut {
  let keyCode = UInt32(
    clamping: defaults.integer(forKey: DefaultsKey.keyCode)
  )
  let modifiers = UInt32(
    clamping: defaults.integer(forKey: DefaultsKey.modifiers)
  )
  let display = defaults.string(forKey: DefaultsKey.hotkeyDisplay)

  guard
    shortcutValidationMessage(
      keyCode: keyCode,
      modifiers: modifiers
    ) == nil,
    let display,
    !display.isEmpty
  else {
    return StoredShortcut(
      keyCode: AppConfiguration.defaultShortcutKeyCode,
      modifiers: defaultCarbonModifiers(),
      display: AppConfiguration.defaultShortcutDisplay
    )
  }

  return StoredShortcut(
    keyCode: keyCode,
    modifiers: modifiers,
    display: display
  )
}

private func fourCharacterCode(_ value: String) -> FourCharCode {
  value.unicodeScalars.prefix(4).reduce(0) {
    ($0 << 8) + FourCharCode($1.value)
  }
}

final class GlobalHotKeyManager {
  typealias Action = HotKeyActionID
  var onHotKey: ((Action) -> Void)?

  private var hotKeyReferences: [Action: EventHotKeyRef] = [:]
  private var handlerReference: EventHandlerRef?
  private var registrations: [Action: (UInt32, UInt32)] = [:]

  init() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let context, let event else { return noErr }
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
          nil, &identifier) == noErr,
          let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
        Unmanaged<GlobalHotKeyManager>
          .fromOpaque(context)
          .takeUnretainedValue()
          .onHotKey?(action)
        return noErr
      },
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerReference
    )
  }

  @discardableResult
  func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
    register(action: .reconnect, keyCode: keyCode, modifiers: modifiers)
  }

  @discardableResult
  func register(action: Action, keyCode: UInt32, modifiers: UInt32) -> OSStatus {
    if hotKeyReferences[action] != nil,
      registrations[action]?.0 == keyCode,
      registrations[action]?.1 == modifiers
    {
      return noErr
    }

    guard handlerReference != nil else {
      return OSStatus(eventNotHandledErr)
    }

    let identifier = EventHotKeyID(
      signature: fourCharacterCode("HSPX"),
      id: action.rawValue
    )
    var candidate: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode,
      modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &candidate
    )
    guard status == noErr, let candidate else {
      return status
    }

    if let hotKeyReference = hotKeyReferences[action] {
      let oldStatus = UnregisterEventHotKey(hotKeyReference)
      guard oldStatus == noErr else {
        UnregisterEventHotKey(candidate)
        return oldStatus
      }
    }

    hotKeyReferences[action] = candidate
    registrations[action] = (keyCode, modifiers)
    return noErr
  }

  func unregister() {
    hotKeyReferences.values.forEach { UnregisterEventHotKey($0) }
    hotKeyReferences.removeAll(); registrations.removeAll()
  }

  func unregister(action: Action) {
    if let hotKeyReference = hotKeyReferences.removeValue(forKey: action) {
      UnregisterEventHotKey(hotKeyReference)
    }
    registrations.removeValue(forKey: action)
  }

  deinit {
    unregister()
    if let handlerReference {
      RemoveEventHandler(handlerReference)
    }
  }
}
