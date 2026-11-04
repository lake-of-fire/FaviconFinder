#if !os(Linux)
import Foundation
import XCTest
@testable import FaviconFinder

final class FaviconURLSessionResponseLimitTests: XCTestCase {
    // Keep the boundary independent of the production constant so a changed
    // cap cannot silently move these regression cases.
    private let limit = 2 * 1024 * 1024

    func testAppleDataTaskAcceptsEmptyResponse() async {
        await checkResponse(size: 0)
    }

    func testAppleDataTaskAcceptsBelowLimitAndPreservesEncodingAndHeaders() async {
        await checkResponse(size: limit - 1)
    }

    func testAppleDataTaskAcceptsExactlyTwoMiB() async {
        await checkResponse(size: limit)
    }

    func testAppleDataTaskRejectsLimitPlusOne() async {
        await checkResponse(size: limit + 1)
    }

    func testAppleDataTaskStopsUnfinishedChunkedOversizeTransport() async {
        await checkResponse(size: limit + 1, finishes: false)
    }

    private func checkResponse(size: Int, finishes: Bool = true) async {
        let fixture = ResponseLimitFixture(size: size, finishes: finishes)
        ResponseLimitProtocol.registry.insert(fixture)
        defer { ResponseLimitProtocol.registry.remove(fixture) }

        let completed = expectation(description: "dataTask returned or threw")
        let exited = expectation(description: "request operation exited")
        let operation = Task {
            defer { exited.fulfill() }
            do {
                let response = try await FaviconURLSession.dataTask(
                    with: fixture.url,
                    httpHeaders: ["X-Favicon-Fixture": fixture.url.host!, "X-Omitted": nil]
                )
                fixture.record(.success(response))
            } catch {
                fixture.record(.failure(error))
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 10)

        if let result = fixture.result {
            if size <= limit {
                switch result {
                case .success(let response):
                    XCTAssertEqual(response.data, fixture.body)
                    XCTAssertEqual(response.textEncoding, .isoLatin1)
                    XCTAssertEqual(String(data: response.data, encoding: response.textEncoding),
                                   String(repeating: "é", count: size))
                case .failure(let error):
                    XCTFail("In-limit response failed: \(error)")
                }
            } else {
                switch result {
                case .success:
                    XCTFail("Oversize response was accepted")
                case .failure(let error):
                    XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum,
                                   "Unexpected oversize error: \(error)")
                }
            }
        } else {
            XCTFail("No public-path result before the bounded wait expired")
        }
        XCTAssertEqual(fixture.receivedRequest?.value(forHTTPHeaderField: "X-Favicon-Fixture"),
                       fixture.url.host)
        XCTAssertNil(fixture.receivedRequest?.value(forHTTPHeaderField: "X-Omitted"))

        if !finishes {
            // This assertion precedes test-owned cancellation. A failure here
            // is evidence that rejecting the body did not stop its transport.
            await fulfillment(of: [fixture.stoppedBeforeCleanup], timeout: 2)
        }

        // Never invalidate the shared session or cancel another test's work.
        // Run this even after an assertion/timeout, while our URL is registered.
        operation.cancel()
        let cancelledOwnTasks = expectation(description: "matching task cleanup")
        URLSession.shared.getAllTasks { tasks in
            for task in tasks where task.originalRequest?.url == fixture.url {
                task.cancel()
            }
            cancelledOwnTasks.fulfill()
        }
        await fulfillment(of: [cancelledOwnTasks], timeout: 2)
        if !finishes {
            await fulfillment(of: [fixture.stoppedAfterCleanup], timeout: 2)
        }
        await fulfillment(of: [exited], timeout: 2)
        // A timeout assertion is not quiescence; keep registration until the operation joins.
        await operation.value
    }
}

private final class ResponseLimitFixture: @unchecked Sendable {
    // A private scheme prevents even a broken fixture registration from
    // sending a request onto the network.
    let url = URL(string: "favicon-cap-test://\(UUID().uuidString.lowercased())/response")!
    let body: Data
    let finishes: Bool
    let stoppedBeforeCleanup = XCTestExpectation(description: "transport stopped without cleanup")
    let stoppedAfterCleanup = XCTestExpectation(description: "transport stopped by end of cleanup")
    private let lock = NSLock()
    private var storedResult: Result<Response, Error>?
    private var storedRequest: URLRequest?
    private var stopped = false

    init(size: Int, finishes: Bool) {
        body = Data(repeating: 0xe9, count: size)
        self.finishes = finishes
    }

    var result: Result<Response, Error>? { lock.withLock { storedResult } }
    var receivedRequest: URLRequest? { lock.withLock { storedRequest } }
    var isStopped: Bool { lock.withLock { stopped } }

    func record(_ result: Result<Response, Error>) {
        lock.withLock { storedResult = result }
    }

    func record(_ request: URLRequest) {
        lock.withLock { storedRequest = request }
    }

    func stop() {
        let firstStop = lock.withLock {
            if stopped { return false }
            stopped = true
            return true
        }
        if firstStop {
            stoppedBeforeCleanup.fulfill()
            stoppedAfterCleanup.fulfill()
        }
    }
}

private final class ResponseLimitProtocol: URLProtocol, @unchecked Sendable {
    static let registry = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var fixtures: [URL: ResponseLimitFixture] = [:]

        func insert(_ fixture: ResponseLimitFixture) {
            lock.withLock {
                if fixtures.isEmpty {
                    XCTAssertTrue(URLProtocol.registerClass(ResponseLimitProtocol.self))
                }
                fixtures[fixture.url] = fixture
            }
        }

        func remove(_ fixture: ResponseLimitFixture) {
            lock.withLock {
                fixtures.removeValue(forKey: fixture.url)
                if fixtures.isEmpty { URLProtocol.unregisterClass(ResponseLimitProtocol.self) }
            }
        }

        func fixture(for request: URLRequest) -> ResponseLimitFixture? {
            lock.withLock { request.url.flatMap { fixtures[$0] } }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        registry.fixture(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.registry.fixture(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        fixture.record(request)
        var headers = ["Content-Type": "text/plain; charset=iso-8859-1"]
        if fixture.finishes {
            headers["Content-Length"] = String(fixture.body.count)
        } else {
            // Deliver chunks, then deliberately leave the response open.
            headers["Transfer-Encoding"] = "chunked"
        }
        let response = HTTPURLResponse(url: fixture.url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: fixture.body.count, by: 64 * 1024) {
            guard !fixture.isStopped else { return }
            let end = min(offset + 64 * 1024, fixture.body.count)
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<end))
        }
        if fixture.finishes && !fixture.isStopped {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.registry.fixture(for: request)?.stop()
    }
}
#endif
