import Foundation
import SwiftSoup
import XCTest
@testable import FaviconFinder
#if os(Linux)
import NIOHTTP1
#endif

final class FaviconForwardPortTests: XCTestCase {
    private let source = URL(string: "https://origin.example.com/page")!
    private let headers: [String: String?] = [
        "Authorization": "TEST_ONLY", "Cookie": "TEST_ONLY", "Proxy-Authorization": "TEST_ONLY",
        "Accept-Language": "ja"
    ]

    func testHTTPAndMetaRefreshShareHeaderHistoryAndOnlyOneMetaRefreshIsFollowed() async throws {
        var requests: [(URL, [String: String?]?)] = []
        let finalBody = "<head><meta http-equiv='refresh' content='0; URL=https://other.example.com/again'></head>"
        let result = try await FaviconURLSession.dataTask(
            with: source, checkForMetaRefreshRedirect: true, httpHeaders: headers
        ) { url, headers in
            requests.append((url, headers))
            switch requests.count {
            case 1: return self.response(url, status: 302, location: "https://other.example.com/folder/landing")
            case 2: return self.response(url, body: "<head><meta http-equiv='Refresh' content='0; URL=../next'></head>")
            case 3: return self.response(url, status: 307, location: "https://origin.example.com/final")
            default: return self.response(url, body: finalBody)
            }
        }
        XCTAssertEqual(requests.map { $0.0.absoluteString }, [source.absoluteString,
            "https://other.example.com/folder/landing", "https://other.example.com/next",
            "https://origin.example.com/final"])
        XCTAssertEqual(requests.first?.1, headers)
        for request in requests.dropFirst() { XCTAssertEqual(request.1, ["Accept-Language": "ja"]) }
        XCTAssertEqual(String(data: result.data, encoding: .utf8), finalBody)
    }

    func testDocumentContextKeepsFinalURLAndSurvivingHeaders() async throws {
        var count = 0
        let result = try await FaviconURLSession.documentTask(
            with: source, checkForMetaRefreshRedirect: true, httpHeaders: headers
        ) { url, _ in
            count += 1
            return count == 1
                ? self.response(url, status: 302, location: "https://other.example.com/dir/page")
                : self.response(url)
        }
        XCTAssertEqual(result.url.absoluteString, "https://other.example.com/dir/page")
        XCTAssertEqual(result.httpHeaders, ["Accept-Language": "ja"])
    }

    func testHTTPLoopHasOneSharedFiniteBudget() async {
        var count = 0
        do {
            _ = try await FaviconURLSession.dataTask(
                with: source, checkForMetaRefreshRedirect: true, httpHeaders: headers
            ) { url, _ in
                count += 1
                return self.response(url, status: 301, location: "/page")
            }
            XCTFail("Expected redirect limit")
        } catch { XCTAssertEqual((error as? URLError)?.code, .httpTooManyRedirects) }
        XCTAssertEqual(count, 11)
    }

    func testNonHTTPRedirectNeverReachesLoader() async {
        var count = 0
        do {
            _ = try await FaviconURLSession.dataTask(
                with: source, checkForMetaRefreshRedirect: false, httpHeaders: nil
            ) { url, _ in
                count += 1
                return self.response(url, status: 302, location: "file:///tmp/not-a-favicon")
            }
            XCTFail("Expected unsupported redirect")
        } catch { XCTAssertEqual((error as? URLError)?.code, .unsupportedURL) }
        XCTAssertEqual(count, 1)
    }

    func testDisabledMetaRefreshDoesNotFetchAnotherPage() async throws {
        var count = 0
        _ = try await FaviconURLSession.dataTask(
            with: source, checkForMetaRefreshRedirect: false, httpHeaders: headers
        ) { url, sentHeaders in
            count += 1
            XCTAssertEqual(sentHeaders, self.headers)
            return self.response(url, body: "<head><meta http-equiv='refresh' content='0; URL=/again'></head>")
        }
        XCTAssertEqual(count, 1)
    }

    func testPrefetchedHTMLKeepsSensitiveHeadersOnTheIconOriginOnly() async throws {
        for destination in ["https://origin.example.com/icon.png", "https://icons.example.net/icon.png"] {
            let document = try SwiftSoup.parse("<head><link rel='icon' href='\(destination)'></head>")
            let icons = try await FaviconFinder(url: source, configuration: .init(
                preferredSource: .html, prefetchedHTML: document, httpHeaders: headers
            )).fetchFaviconURLs()
            let icon = try XCTUnwrap(icons.first)
            let expected = icon.source.host == source.host ? headers : ["Accept-Language": "ja"]
            XCTAssertEqual(icon.httpHeaders, expected)
        }
    }

    func testICORequestsAndReturnedImagesRetainOnlyTheirOriginHeaders() async throws {
        let image = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII="))
        for (preferred, rejectFirst) in [("favicon.ico", false), ("favicon.ico", true),
                                       ("https://icons.example.net/a.png", false)] {
            var requests: [(URL, [String: String?]?)] = []
            let finder = ICOFaviconFinder(url: source, configuration: .init(
                preferences: [.ico: preferred], httpHeaders: headers
            ), isValidImage: { $0 == image }) { url, _, headers in
                requests.append((url, headers))
                return rejectFirst && requests.count == 1 ? Data("not an image".utf8) : image
            }
            let icons = try await finder.find()
            let icon = try XCTUnwrap(icons.first)
            XCTAssertEqual(requests.count, rejectFirst ? 2 : 1)
            for request in requests {
                XCTAssertEqual(request.1, request.0.host == source.host ? headers : ["Accept-Language": "ja"])
            }
            XCTAssertEqual(icon.httpHeaders, requests.last?.1)
            XCTAssertEqual(icon.source.absoluteURL, requests.last?.0.absoluteURL)
        }
    }

    func testFetchedHTMLUsesFinalDocumentURLWithoutRestoringHeaders() async throws {
        let finalURL = URL(string: "https://other.example.com/folder/page")!
        let body = "<head><link rel='icon' href='../icon.png'><link rel='icon' href='https://origin.example.com/icon.png'></head>"
        let finder = HTMLFaviconFinder(url: source, configuration: .init(httpHeaders: headers)) { _, _, _ in
            .init(response: self.response(finalURL, body: body).response,
                  url: finalURL, httpHeaders: ["Accept-Language": "ja"])
        }
        let icons = try await finder.find()
        XCTAssertEqual(icons.map { $0.source.absoluteString },
                       ["https://other.example.com/icon.png", "https://origin.example.com/icon.png"])
        for icon in icons { XCTAssertEqual(icon.httpHeaders, ["Accept-Language": "ja"]) }
    }

    func testManifestUsesItsFinalURLAllowsOrdinaryNamesAndOptionalSizes() async throws {
        let html = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
        let finalURL = URL(string: "https://cdn.example.net/manifests/app.webmanifest")!
        let body = #"{"icons":[{"src":"../icons/a.png"},{"src":"https://origin.example.com/b.png","sizes":"any"},{"src":"launcher-icon-1x.png","sizes":"16x16"}]}"#
        var requests = 0
        let finder = WebApplicationManifestFaviconFinder(url: source,
            configuration: .init(prefetchedHTML: html, httpHeaders: headers)
        ) { url, _, sentHeaders in
            requests += 1
            XCTAssertEqual(url.absoluteString, "https://origin.example.com/app.webmanifest")
            XCTAssertEqual(sentHeaders, self.headers)
            return .init(response: self.response(finalURL, body: body).response,
                         url: finalURL, httpHeaders: ["Accept-Language": "ja"])
        }
        let icons = try await finder.find()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(icons.map { $0.source.absoluteString }, ["https://cdn.example.net/icons/a.png",
            "https://origin.example.com/b.png", "https://cdn.example.net/manifests/launcher-icon-1x.png"])
        XCTAssertEqual(icons.map { $0.format }, [.icon, .icon, .launcherIcon1x])
        XCTAssertNil(icons[0].size)
        XCTAssertNil(icons[1].size)
        for icon in icons { XCTAssertEqual(icon.httpHeaders, ["Accept-Language": "ja"]) }
    }

    func testCancellationDuringLoadCannotPublishAResponse() async {
        let source = self.source
        let task = Task {
            do {
                _ = try await FaviconURLSession.dataTask(with: source,
                    checkForMetaRefreshRedirect: false, httpHeaders: nil
                ) { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.cancelled)
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    func testIconMetadataEqualityDoesNotDependOnCredentials() {
        let first = FaviconURL(source: source, format: .ico, sourceType: .ico, httpHeaders: headers)
        let second = FaviconURL(source: source, format: .ico, sourceType: .ico)
        XCTAssertEqual(first, second)
    }

    private func response(_ url: URL, status: Int = 200, location: String? = nil,
                          body: String = "icon") -> FaviconURLSession.LoadedResponse {
        let data = Data(body.utf8)
#if os(Linux)
        let response = Response((data, HTTPHeaders([("content-type", "text/html; charset=utf-8")])))
#else
        let metadata = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        let response = Response((data, metadata))
#endif
        return .init(response: response, statusCode: status, location: location)
    }
}
