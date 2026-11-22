import Foundation
import XCTest
@testable import FaviconFinder

final class ICOFaviconHTTPStatusTests: XCTestCase {
    private let source = URL(string: "https://tenant.example.com/page")!

    func testICO404UsesRootFallbackWithFilteredHeaders() async throws {
        let requests = ICOHTTPRequests()
        let headers: [String: String?] = [
            "Authorization": "TEST_ONLY", "cOoKiE": "TEST_ONLY",
            "Proxy-Authorization": "TEST_ONLY", "Accept-Language": "ja"
        ]
        let iconData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=="
        ))
        let finder = ICOFaviconFinder(url: source, configuration: .init(httpHeaders: headers)) { url, _, headers in
            if await requests.record(url, headers: headers) == 1 {
                throw FaviconURLSession.HTTPStatusError(statusCode: 404)
            }
            return iconData
        }

        let icons = try await finder.find()

        let recorded = await requests.recorded
        XCTAssertEqual(recorded.map(\.url.absoluteString), [
            "https://tenant.example.com/favicon.ico", "https://example.com/favicon.ico"
        ])
        XCTAssertEqual(recorded.first?.headers, headers)
        XCTAssertEqual(recorded.last?.headers, ["Accept-Language": "ja"])
        XCTAssertEqual(icons.count, 1)
        XCTAssertEqual(icons.first?.source.absoluteURL, recorded.last?.url.absoluteURL)
        XCTAssertEqual(icons.first?.httpHeaders, recorded.last?.headers)
    }

    func testICONon404StatusDoesNotUseRootFallback() async throws {
        for statusCode in [401, 403, 500] {
            let requests = ICOHTTPRequests()
            let finder = ICOFaviconFinder(url: source, configuration: .init()) { url, _, headers in
                await requests.record(url, headers: headers)
                throw FaviconURLSession.HTTPStatusError(statusCode: statusCode)
            }

            do {
                _ = try await finder.find()
                XCTFail("Expected HTTP \(statusCode) to fail")
            } catch let error as FaviconURLSession.HTTPStatusError {
                XCTAssertEqual(error.statusCode, statusCode)
            }
            let recorded = await requests.recorded
            XCTAssertEqual(recorded.map(\.url.host), [source.host])
        }
    }

    func testICORoot404TerminatesAfterOneFallback() async throws {
        let requests = ICOHTTPRequests()
        let finder = ICOFaviconFinder(url: source, configuration: .init()) { url, _, headers in
            await requests.record(url, headers: headers)
            throw FaviconURLSession.HTTPStatusError(statusCode: 404)
        }

        do {
            _ = try await finder.find()
            XCTFail("Expected the root fallback's 404 to fail")
        } catch let error as FaviconURLSession.HTTPStatusError {
            XCTAssertEqual(error.statusCode, 404)
        }
        let recorded = await requests.recorded
        XCTAssertEqual(recorded.map(\.url.host), [source.host, "example.com"])
    }

    func testICOTransportErrorDoesNotUseRootFallback() async throws {
        let requests = ICOHTTPRequests()
        let finder = ICOFaviconFinder(url: source, configuration: .init()) { url, _, headers in
            await requests.record(url, headers: headers)
            throw URLError(.timedOut)
        }

        do {
            _ = try await finder.find()
            XCTFail("Expected the transport error to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        let recorded = await requests.recorded
        XCTAssertEqual(recorded.map(\.url.host), [source.host])
    }

    func testICOCancellationAfter404DoesNotUseRootFallback() async throws {
        let requests = ICOHTTPRequests()
        let source = self.source
        let operation = Task {
            let finder = ICOFaviconFinder(url: source, configuration: .init()) { url, _, headers in
                await requests.record(url, headers: headers)
                withUnsafeCurrentTask { $0?.cancel() }
                throw FaviconURLSession.HTTPStatusError(statusCode: 404)
            }
            return try await finder.find().map(\.source)
        }

        do {
            _ = try await operation.value
            XCTFail("Expected cancellation before root fallback")
        } catch is CancellationError {
        }
        let recorded = await requests.recorded
        XCTAssertEqual(recorded.map(\.url.host), [source.host])
    }
}

private actor ICOHTTPRequests {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String?]?
    }

    private(set) var recorded: [Request] = []

    @discardableResult
    func record(_ url: URL, headers: [String: String?]?) -> Int {
        recorded.append(.init(url: url, headers: headers))
        return recorded.count
    }
}
