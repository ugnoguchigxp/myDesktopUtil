import DeskCore
import Foundation

final class RestrictedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let isAllowed: @Sendable (URL) -> Bool

  init(isAllowed: @escaping @Sendable (URL) -> Bool) {
    self.isAllowed = isAllowed
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, isAllowed(url) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
