import Foundation
import XCTest
@testable import FaviconFinder

final class FaviconRequestPolicyTests: XCTestCase {
    private let source = URL(string: "https://catalog.example.com/book/page")!
    private let headers: [String: String?] = [
        "Authorization": "TEST_ONLY", "cOoKiE": "TEST_ONLY",
        "Proxy-Authorization": "TEST_ONLY", "Host": "catalog.example.com", "Accept-Language": "ja"
    ]

    func testSameOriginIncludesImplicitDefaultPortAndIgnoresHostCase() {
        let result = FaviconRequestPolicy.headers(headers, from: source,
            to: URL(string: "https://CATALOG.example.com:443/icon.png")!)
        XCTAssertEqual(result, headers)
    }

    func testCustomCredentialsStayOnTheirOrigin() {
        let custom: [String: String?] = ["X-Api-Key": "TEST_ONLY", "X-Session": "TEST_ONLY", "User-Agent": "Tests"]
        XCTAssertEqual(FaviconRequestPolicy.headers(custom, from: source, to: source), custom)
        XCTAssertEqual(FaviconRequestPolicy.headers(custom, from: source,
            to: URL(string: "https://other.example.com/icon")!), ["User-Agent": "Tests"])
    }

    func testHostPortAndSchemeChangesStripSensitiveHeaders() {
        for target in ["https://icons.example.com/a", "https://catalog.example.com:444/a",
                       "http://catalog.example.com/a"] {
            let result = FaviconRequestPolicy.headers(headers, from: source, to: URL(string: target)!)
            XCTAssertEqual(result, ["Accept-Language": "ja"], target)
        }
    }

    func testNilHeaderValuesAreOmittedButExplicitEmptyValuesSurvive() {
        let result = FaviconRequestPolicy.headers(["X-Absent": nil, "X-Empty": ""], from: source, to: source)
        XCTAssertEqual(result, ["X-Empty": ""])
        XCTAssertNil(FaviconRequestPolicy.headers(nil, from: source, to: source))
    }

    func testRelativeMetaRefreshUsesDocumentDirectoryAndKeepsQueryAndFragment() {
        let value = FaviconRequestPolicy.metaRefreshURL(
            content: "0; uRl = '../icons/a.png?q=1#image'", relativeTo: source)
        XCTAssertEqual(value?.absoluteString, "https://catalog.example.com/icons/a.png?q=1#image")
    }

    func testMalformedAndNonHTTPMetaRefreshIsNotFollowed() {
        for content in ["", "0", "0; target=/a", "0; URL=", "0; URL='broken",
                        "0; URL=file:///tmp/a", "0; URL=data:text/html,a", "0; URL=javascript:alert(1)",
                        "0; URL=https://user:password@example.com/a", "0; URL=bad\\path"] {
            XCTAssertNil(FaviconRequestPolicy.metaRefreshURL(content: content, relativeTo: source), content)
        }
    }

    func testSchemeRelativeMetaRefreshAndQuotedSemicolonArePreserved() {
        XCTAssertEqual(FaviconRequestPolicy.metaRefreshURL(content: "1; URL=//icons.example.com/a",
            relativeTo: source)?.absoluteString, "https://icons.example.com/a")
        XCTAssertEqual(FaviconRequestPolicy.metaRefreshURL(content: "0; URL=\"/a;b?q=c=d\"",
            relativeTo: source)?.absoluteString, "https://catalog.example.com/a;b?q=c=d")
    }

    func testCredentialsAreNotRestoredAfterReturningFromAnotherOrigin() throws {
        var state = try FaviconRedirectState(url: source, httpHeaders: headers)
        try state.follow(URL(string: "https://other.example.com/landing")!)
        try state.follow(source)
        XCTAssertEqual(state.httpHeaders, ["Accept-Language": "ja"])
        XCTAssertEqual(state.followedRedirects, 2)
    }

    func testRedirectBudgetAllowsExactlyTenHopsAndDoesNotMutateAfterRejection() throws {
        var state = try FaviconRedirectState(url: source, httpHeaders: headers)
        for _ in 0..<10 { try state.follow(source) }
        XCTAssertThrowsError(try state.follow(URL(string: "https://other.example.com/a")!)) {
            XCTAssertEqual(($0 as? URLError)?.code, .httpTooManyRedirects)
        }
        XCTAssertEqual(state.url, source)
        XCTAssertEqual(state.httpHeaders, headers)
        XCTAssertEqual(state.followedRedirects, 10)
    }

    func testUnsupportedInitialAndRedirectURLsAreRejected() throws {
        XCTAssertThrowsError(try FaviconRedirectState(url: URL(fileURLWithPath: "/tmp/a"), httpHeaders: nil))
        var state = try FaviconRedirectState(url: source, httpHeaders: headers)
        XCTAssertThrowsError(try state.follow(URL(fileURLWithPath: "/tmp/a")))
        XCTAssertEqual(state.url, source)
        XCTAssertEqual(state.followedRedirects, 0)
    }

    func testCollectorAcceptsEmptyAndExactBoundaryBodies() async throws {
        let empty = try await FaviconRequestPolicy.collect(TestBytes(count: 0), maximumBytes: 0)
        let exact = try await FaviconRequestPolicy.collect(TestBytes(count: 4), maximumBytes: 4)
        XCTAssertEqual(empty, Data())
        XCTAssertEqual(exact, Data(repeating: 7, count: 4))
    }

    func testCollectorRejectsFirstExcessByteAndInvalidBudget() async {
        for maximum in [0, 4, -1] {
            do {
                _ = try await FaviconRequestPolicy.collect(TestBytes(count: 5), maximumBytes: maximum)
                XCTFail("Expected overflow for budget \(maximum)")
            } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
        }
    }

    func testCollectorPropagatesStreamFailure() async {
        do {
            _ = try await FaviconRequestPolicy.collect(TestBytes(count: 4, failureAt: 2), maximumBytes: 4)
            XCTFail("Expected transport failure")
        } catch { XCTAssertEqual(error as? ByteFailure, .injected) }
    }

    func testCollectorHonorsCancellationEvenForAnEmptyStream() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await FaviconRequestPolicy.collect(TestBytes(count: 0), maximumBytes: 4)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    func testProductionLimitAcceptsTwoMiBButNotAnExtraByte() async throws {
        let limit = FaviconRequestPolicy.maximumResponseBytes
        XCTAssertEqual(limit, 2 * 1024 * 1024)
        let data = try await FaviconRequestPolicy.collect(TestBytes(count: limit))
        XCTAssertEqual(data.count, limit)
        do {
            _ = try await FaviconRequestPolicy.collect(TestBytes(count: limit + 1))
            XCTFail("Expected production cap")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
    }
}

private enum ByteFailure: Error { case injected }

private struct TestBytes: AsyncSequence, AsyncIteratorProtocol {
    typealias Element = UInt8
    var count: Int
    var failureAt: Int? = nil
    private var index = 0

    init(count: Int, failureAt: Int? = nil) { self.count = count; self.failureAt = failureAt }
    func makeAsyncIterator() -> Self { self }
    mutating func next() async throws -> UInt8? {
        if index == failureAt { throw ByteFailure.injected }
        guard index < count else { return nil }
        index += 1
        return 7
    }
}
