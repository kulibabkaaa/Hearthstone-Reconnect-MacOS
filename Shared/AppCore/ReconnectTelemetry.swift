import Foundation

/// Which control started a reconnect, sent with the success signal (`reconnect.source`).
public enum ReconnectSource: String, CaseIterable, Sendable {
  case shortcut
  case overlayButton
  /// "Reconnect Now" in the main window.
  case mainWindow
  /// "Reconnect" in the menu bar menu.
  case menu
}

public enum ReconnectTelemetry {
  /// TelemetryDeck parameter key; the SDK adds no prefix to parameters.
  public static let sourceParameter = "reconnect.source"
  /// Parameters for `Reconnect.Succeeded`: only the source, nothing identifying.
  public static func successParameters(source: ReconnectSource) -> [String: String] {
    [sourceParameter: source.rawValue]
  }
}
