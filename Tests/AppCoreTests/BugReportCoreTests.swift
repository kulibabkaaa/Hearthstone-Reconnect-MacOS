import Foundation
import Testing
@testable import AppCore

struct BugReportCoreTests {
  @Test func trimsDescriptionAndBuildsMessage() throws {
    let content = try BugReportContent(
      description: "  Overlay disappeared after reconnect.  \n",
      appVersion: "1.3.0",
      buildNumber: "9",
      macOSVersion: "15.6"
    )

    #expect(content.description == "Overlay disappeared after reconnect.")
    #expect(content.appVersion == "1.3.0")
    #expect(content.buildNumber == "9")
    #expect(content.macOSVersion == "15.6")
  }

  @Test func rejectsEmptyDescription() {
    #expect(throws: BugReportValidationError.emptyDescription) {
      _ = try BugReportContent(
        description: "  \n ",
        appVersion: "1.3.0",
        buildNumber: "9",
        macOSVersion: "15.6"
      )
    }
  }

  @Test func rejectsDescriptionBelowMinimumLength() {
    #expect(throws: BugReportValidationError.descriptionTooShort) {
      _ = try BugReportContent(
        description: String(
          repeating: "a",
          count: BugReportContent.minimumDescriptionLength - 1
        ),
        appVersion: "1.3.0",
        buildNumber: "17",
        macOSVersion: "15.6"
      )
    }
  }

  @Test func acceptsDescriptionAtMinimumLength() throws {
    let description = String(
      repeating: "a",
      count: BugReportContent.minimumDescriptionLength
    )
    let content = try BugReportContent(
      description: "  \(description)  ",
      appVersion: "1.3.0",
      buildNumber: "17",
      macOSVersion: "15.6"
    )

    #expect(content.description == description)
    #expect(
      BugReportContent.descriptionLength("  \(description)  ")
        == BugReportContent.minimumDescriptionLength
    )
  }

  @Test func rejectsDescriptionOverLimit() {
    #expect(throws: BugReportValidationError.descriptionTooLong) {
      _ = try BugReportContent(
        description: String(
          repeating: "a",
          count: BugReportContent.maximumDescriptionLength + 1
        ),
        appVersion: "1.3.0",
        buildNumber: "9",
        macOSVersion: "15.6"
      )
    }
  }

  @Test func acceptsOnlyTheConfiguredHTTPSFormHost() throws {
    let endpoint = try BugReportContent.validatedFormEndpoint(
      "https://forminit.com/f/example"
    )
    #expect(endpoint.absoluteString == "https://forminit.com/f/example")

    #expect(throws: BugReportValidationError.invalidEndpoint) {
      _ = try BugReportContent.validatedFormEndpoint(
        "http://forminit.com/f/example"
      )
    }
    #expect(throws: BugReportValidationError.invalidEndpoint) {
      _ = try BugReportContent.validatedFormEndpoint(
        "https://example.com/f/example"
      )
    }
    #expect(throws: BugReportValidationError.invalidEndpoint) {
      _ = try BugReportContent.validatedFormEndpoint(
        "https://forminit.com/f/example/extra"
      )
    }
    #expect(throws: BugReportValidationError.invalidEndpoint) {
      _ = try BugReportContent.validatedFormEndpoint(
        "https://user@forminit.com/f/example"
      )
    }
  }

  @Test func permitsOnlySameOriginHTTPSRedirects() throws {
    let endpoint = try BugReportContent.validatedFormEndpoint(
      "https://forminit.com/f/example"
    )
    #expect(
      BugReportContent.allowsRedirect(
        from: endpoint,
        to: URL(string: "https://forminit.com/thanks")!
      )
    )
    #expect(
      !BugReportContent.allowsRedirect(
        from: endpoint,
        to: URL(string: "https://attacker.example/collect")!
      )
    )
    #expect(
      !BugReportContent.allowsRedirect(
        from: endpoint,
        to: URL(string: "http://forminit.com/thanks")!
      )
    )
  }

  @Test func rejectsOversizedOrMalformedSourceImages() {
    #expect(
      BugReportContent.maximumTotalImageBytes
        < 25 * 1_024 * 1_024
    )
    #expect(
      BugReportContent.acceptsSourceImage(
        byteCount: 1_024,
        pixelWidth: 4_000,
        pixelHeight: 3_000
      )
    )
    #expect(
      !BugReportContent.acceptsSourceImage(
        byteCount: BugReportContent.maximumSourceImageBytes + 1,
        pixelWidth: 1,
        pixelHeight: 1
      )
    )
    #expect(
      !BugReportContent.acceptsSourceImage(
        byteCount: 1_024,
        pixelWidth: 20_000,
        pixelHeight: 20_000
      )
    )
    #expect(
      !BugReportContent.acceptsSourceImage(
        byteCount: 1_024,
        pixelWidth: 0,
        pixelHeight: 100
      )
    )
  }

  @Test func multipartBodyIncludesMetadataAndMultipleImages() throws {
    let content = try BugReportContent(
      description: "Overlay vanished after reconnect.",
      appVersion: "1.3.0",
      buildNumber: "9",
      macOSVersion: "15.6"
    )
    let body = BugReportMultipartBody(
      content: content,
      imageJPEGs: [
        Data([0xFF, 0xD8, 0x01]),
        Data([0xFF, 0xD8, 0x02]),
      ],
      boundary: "test-boundary"
    )
    let text = String(decoding: body.data, as: UTF8.self)

    #expect(body.contentType == "multipart/form-data; boundary=test-boundary")
    #expect(text.contains("name=\"fi-text-description\""))
    #expect(text.contains("Overlay vanished after reconnect."))
    #expect(text.contains("name=\"fi-text-app-version\""))
    #expect(
      text.components(
        separatedBy: "name=\"fi-file-images[]\""
      ).count - 1 == 2
    )
    #expect(text.contains("filename=\"hs-reconnect-image-1.jpg\""))
    #expect(text.contains("filename=\"hs-reconnect-image-2.jpg\""))
    #expect(text.hasSuffix("--test-boundary--\r\n"))
  }

  @Test func multipartBodyLimitsImagesToFive() throws {
    let content = try BugReportContent(
      description: "Overlay vanished after reconnect.",
      appVersion: "1.3.0",
      buildNumber: "9",
      macOSVersion: "15.6"
    )
    let body = BugReportMultipartBody(
      content: content,
      imageJPEGs: Array(repeating: Data([0xFF]), count: 6),
      boundary: "test-boundary"
    )
    let text = String(decoding: body.data, as: UTF8.self)

    #expect(
      text.components(
        separatedBy: "name=\"fi-file-images[]\""
      ).count - 1 == BugReportContent.maximumImageCount
    )
    #expect(!text.contains("hs-reconnect-image-6.jpg"))
  }
}
