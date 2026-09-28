#if !os(Linux)
import Foundation
import XCTest
@testable import FaviconFinder

final class FaviconAppleBoundedTransportTests: XCTestCase {
    func testEmptyAndExactlyTwoMiBBodiesAreAccepted() async throws {
        for path in ["empty", "exact"] {
            let session = session()
            defer { session.invalidateAndCancel() }
            let (data, response) = try await FaviconURLSession.boundedData(
                for: URLRequest(url: URL(string: "https://bounded.invalid/\(path)")!), session: session)
            XCTAssertEqual(data.count, path == "empty" ? 0 : FaviconURLSession.maximumResponseBytes)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
    }

    func testUnknownLengthOverLimitBodyIsRejected() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await FaviconURLSession.boundedData(
                for: URLRequest(url: URL(string: "https://bounded.invalid/over")!), session: session)
            XCTFail("Expected overflow")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }

    func testStreamingFailureIsNotReportedAsSuccess() async {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await FaviconURLSession.boundedData(
                for: URLRequest(url: URL(string: "https://bounded.invalid/failure")!), session: session)
            XCTFail("Expected connection failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// URL-keyed responses avoid a process-global mutable test handler.
private final class BoundedFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "image/png"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.lastPathComponent == "failure" {
            client?.urlProtocol(self, didLoad: Data([7]))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if url.lastPathComponent != "empty" {
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: FaviconURLSession.maximumResponseBytes))
        }
        if url.lastPathComponent == "over" { client?.urlProtocol(self, didLoad: Data([8])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
