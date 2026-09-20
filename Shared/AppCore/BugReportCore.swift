import Foundation

public enum BugReportValidationError: Error, Equatable {
  case emptyDescription
  case descriptionTooLong
  case invalidEndpoint
}

public struct BugReportContent: Equatable {
  public static let maximumDescriptionLength = 4_000
  public static let maximumImageCount = 5
  public static let maximumImageBytes = 5 * 1_024 * 1_024
  public static let maximumTotalImageBytes = 24 * 1_024 * 1_024
  public static let maximumSourceImageBytes = 25 * 1_024 * 1_024
  public static let maximumSourceImageDimension = 32_768
  public static let maximumSourceImagePixels = 100_000_000

  public let description: String
  public let appVersion: String
  public let buildNumber: String
  public let macOSVersion: String

  public init(
    description: String,
    appVersion: String,
    buildNumber: String,
    macOSVersion: String
  ) throws {
    let trimmed = description.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmed.isEmpty else {
      throw BugReportValidationError.emptyDescription
    }
    guard trimmed.count <= Self.maximumDescriptionLength else {
      throw BugReportValidationError.descriptionTooLong
    }

    self.description = trimmed
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.macOSVersion = macOSVersion
  }

  public static func validatedFormEndpoint(
    _ endpointString: String?
  ) throws -> URL {
    guard
      let endpointString,
      let endpoint = URL(string: endpointString),
      endpoint.scheme == "https",
      endpoint.host == "forminit.com",
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.port == nil || endpoint.port == 443,
      endpoint.query == nil,
      endpoint.fragment == nil,
      endpoint.pathComponents.count == 3,
      endpoint.pathComponents[1] == "f",
      endpoint.pathComponents[2].range(
        of: "^[A-Za-z0-9_-]+$",
        options: .regularExpression
      ) != nil
    else {
      throw BugReportValidationError.invalidEndpoint
    }
    return endpoint
  }

  public static func allowsRedirect(
    from original: URL,
    to destination: URL
  ) -> Bool {
    original.scheme?.lowercased() == "https"
      && destination.scheme?.lowercased() == "https"
      && original.host?.lowercased() == destination.host?.lowercased()
      && effectivePort(of: original) == effectivePort(of: destination)
  }

  public static func acceptsSourceImage(
    byteCount: Int,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> Bool {
    guard
      byteCount > 0,
      byteCount <= maximumSourceImageBytes,
      pixelWidth > 0,
      pixelHeight > 0,
      pixelWidth <= maximumSourceImageDimension,
      pixelHeight <= maximumSourceImageDimension
    else {
      return false
    }
    let (pixels, overflow) = pixelWidth.multipliedReportingOverflow(
      by: pixelHeight
    )
    return !overflow && pixels <= maximumSourceImagePixels
  }

  private static func effectivePort(of url: URL) -> Int? {
    url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
  }
}

public struct BugReportMultipartBody {
  public let contentType: String
  public let data: Data

  public init(
    content: BugReportContent,
    imageJPEGs: [Data],
    boundary: String = "HSReconnect-\(UUID().uuidString)"
  ) {
    var body = Data()
    Self.append("HS Reconnect User", name: "fi-sender-fullName", boundary: boundary, to: &body)
    Self.append(content.description, name: "fi-text-description", boundary: boundary, to: &body)
    Self.append(content.appVersion, name: "fi-text-app-version", boundary: boundary, to: &body)
    Self.append(content.buildNumber, name: "fi-text-build-number", boundary: boundary, to: &body)
    Self.append(content.macOSVersion, name: "fi-text-macos-version", boundary: boundary, to: &body)
    for (index, imageJPEG) in imageJPEGs
      .prefix(BugReportContent.maximumImageCount)
      .enumerated()
    {
      Self.append(
        imageJPEG,
        name: "fi-file-images[]",
        filename: "hs-reconnect-image-\(index + 1).jpg",
        contentType: "image/jpeg",
        boundary: boundary,
        to: &body
      )
    }
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    contentType = "multipart/form-data; boundary=\(boundary)"
    data = body
  }

  private static func append(
    _ value: String,
    name: String,
    boundary: String,
    to body: inout Data
  ) {
    let escapedValue = value.replacingOccurrences(of: "\r\n", with: "\n")
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        .data(using: .utf8)!
    )
    body.append(escapedValue.data(using: .utf8)!)
    body.append("\r\n".data(using: .utf8)!)
  }

  private static func append(
    _ data: Data,
    name: String,
    filename: String,
    contentType: String,
    boundary: String,
    to body: inout Data
  ) {
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        .data(using: .utf8)!
    )
    body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n".data(using: .utf8)!)
  }
}
