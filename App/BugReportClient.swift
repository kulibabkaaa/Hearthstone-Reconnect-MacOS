import Foundation

enum BugReportClientError: Error {
  case notConfigured
  case invalidEndpoint
  case invalidAttachment
  case rejected
  case invalidResponse
}

private final class BugReportRedirectDelegate:
  NSObject,
  URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let endpoint: URL

  init(endpoint: URL) {
    self.endpoint = endpoint
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let destination = request.url,
      BugReportContent.allowsRedirect(
        from: endpoint,
        to: destination
      )
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

final class BugReportClient {
  private let session: URLSession
  private let endpoint: URL?

  init(
    session: URLSession? = nil,
    endpointString: String? = Bundle.main.object(
      forInfoDictionaryKey: "HSRBugReportEndpoint"
    ) as? String
  ) {
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(configuration: configuration)
    }
    endpoint = try? BugReportContent.validatedFormEndpoint(endpointString)
  }

  func submit(
    content: BugReportContent,
    imageURLs: [URL]
  ) async throws {
    guard let endpoint else {
      throw BugReportClientError.notConfigured
    }
    guard imageURLs.count <= BugReportContent.maximumImageCount else {
      throw BugReportClientError.invalidAttachment
    }
    let imageData = try imageURLs.map { url in
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .fileSizeKey]
      )
      guard
        values.isRegularFile == true,
        let byteCount = values.fileSize,
        byteCount > 0,
        byteCount <= BugReportContent.maximumImageBytes
      else {
        throw BugReportClientError.invalidAttachment
      }
      let data = try Data(
        contentsOf: url,
        options: [.mappedIfSafe, .uncached]
      )
      guard data.count <= BugReportContent.maximumImageBytes else {
        throw BugReportClientError.invalidAttachment
      }
      return data
    }
    guard
      imageData.reduce(0, { $0 + $1.count })
        <= BugReportContent.maximumTotalImageBytes
    else {
      throw BugReportClientError.invalidAttachment
    }
    let multipart = BugReportMultipartBody(
      content: content,
      imageJPEGs: imageData
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue(
      multipart.contentType,
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = multipart.data

    let (_, response) = try await session.data(
      for: request,
      delegate: BugReportRedirectDelegate(endpoint: endpoint)
    )
    guard let response = response as? HTTPURLResponse else {
      throw BugReportClientError.invalidResponse
    }
    guard (200 ... 299).contains(response.statusCode) else {
      throw BugReportClientError.rejected
    }
  }

}
