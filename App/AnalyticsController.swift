import Foundation
import OSLog
import TelemetryDeck

enum AnalyticsEvent: String {
  case reconnectSucceeded = "Reconnect.Succeeded"
  case lobbyDisplayed = "LobbyInfo.Displayed"
}

final class AnalyticsController {
  private let logger = Logger(
    subsystem: AppConfiguration.bundleIdentifier,
    category: "Analytics"
  )
  private var isStarted = false

  func start() {
    guard !isStarted else { return }
    guard
      let appID = Bundle.main.object(
        forInfoDictionaryKey: "HSRTelemetryDeckAppID"
      ) as? String,
      UUID(uuidString: appID) != nil
    else {
      logger.error("TelemetryDeck configuration is missing or invalid")
      return
    }

    let configuration = TelemetryDeck.Config(appID: appID)
    configuration.defaultSignalPrefix = "HSReconnect."
    configuration.logHandler = .standard(.error)
    TelemetryDeck.initialize(config: configuration)
    isStarted = true
  }

  /// `parameters`: non-identifying values only (see `ReconnectTelemetry`).
  func signal(_ event: AnalyticsEvent, parameters: [String: String] = [:]) {
    guard isStarted else { return }
    // Tests/ReleaseContract checks for the plain call below.
    if parameters.isEmpty {
      TelemetryDeck.signal(event.rawValue)
    } else {
      TelemetryDeck.signal(event.rawValue, parameters: parameters)
    }
  }

  func flush() {
    guard isStarted else { return }
    TelemetryDeck.requestImmediateSync()
  }
}
