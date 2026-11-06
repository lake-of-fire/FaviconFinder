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

    func testHTTPFailureBodiesAreRejectedBeforeParsingOrMetaRefresh() async {
        let body = "<head><link rel='icon' href='/error-icon.png'><meta http-equiv='refresh' content='0; URL=/retry'></head>"
        for status in [101, 300, 301, 302, 303, 304, 307, 308, 400, 401, 403, 404, 429, 500, 503] {
            var requests = 0
            do {
                _ = try await FaviconURLSession.documentTask(with: source,
                    checkForMetaRefreshRedirect: true, httpHeaders: headers
                ) { url, _ in
                    requests += 1
                    return self.response(url, status: status, body: body)
                }
                XCTFail("HTTP \(status) must not be admitted as a favicon document")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .badServerResponse, "HTTP \(status)")
            }
            XCTAssertEqual(requests, 1, "An error body must not trigger meta refresh")
        }
    }

    func testHTTPRedirectToErrorResponseFailsWithoutPublishingItsBody() async {
        var requests = 0
        do {
            _ = try await FaviconURLSession.dataTask(with: source,
                checkForMetaRefreshRedirect: false, httpHeaders: headers
            ) { url, _ in
                requests += 1
                return requests == 1
                    ? self.response(url, status: 302, location: "/unavailable")
                    : self.response(url, status: 503, body: "error image bytes")
            }
            XCTFail("Redirecting to an HTTP failure must not publish image data")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
        XCTAssertEqual(requests, 2)
    }

    func testSuccessfulHTTPResponsePreservesItsBody() async throws {
        for status in [200, 201, 206, 299] {
            let response = try await FaviconURLSession.dataTask(with: source,
                checkForMetaRefreshRedirect: false, httpHeaders: headers
            ) { url, _ in
                self.response(url, status: status, body: "favicon data")
            }
            XCTAssertEqual(response.data, Data("favicon data".utf8))
        }
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

    func testManifestPreferenceSelectsIconWithoutChangingLinkRelation() async throws {
        let html = try SwiftSoup.parse("""
            <head><base href='/assets/'>
            <link rel='preferred.png' href='wrong.json'>
            <link rel='alternate MANIFEST' href='app.webmanifest'></head>
            """)
        let finalURL = URL(string: "https://cdn.example.net/manifests/app.webmanifest")!
        let body = #"{"icons":[{"src":"first.png"},{"src":"preferred.png"},{"src":"last.png"}]}"#
        var requests: [URL] = []
        let finder = WebApplicationManifestFaviconFinder(url: source,
            configuration: .init(preferences: [.webApplicationManifestFile: "preferred.png"],
                                 prefetchedHTML: html, httpHeaders: headers)
        ) { url, _, sentHeaders in
            requests.append(url)
            XCTAssertEqual(sentHeaders, self.headers)
            return .init(response: self.response(finalURL, body: body).response,
                         url: finalURL, httpHeaders: ["Accept-Language": "ja"])
        }
        let icons = try await finder.find()
        XCTAssertEqual(requests.map(\.absoluteString), ["https://origin.example.com/assets/app.webmanifest"])
        XCTAssertEqual(icons.map { $0.source.absoluteString }, [
            "https://cdn.example.net/manifests/preferred.png",
            "https://cdn.example.net/manifests/first.png",
            "https://cdn.example.net/manifests/last.png"
        ])
        for icon in icons { XCTAssertEqual(icon.httpHeaders, ["Accept-Language": "ja"]) }
    }

    func testUnmatchedOrUnsafeManifestPreferencePreservesDeclaredIconOrder() async throws {
        let html = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
        let body = #"{"icons":[{"src":"first.png"},{"src":"last.png"}]}"#
        for preference in ["", "missing.png", "file:///tmp/preferred.png",
                           "https://user:password@origin.example.com/first.png"] {
            var requests = 0
            let finder = WebApplicationManifestFaviconFinder(url: source,
                configuration: .init(preferences: [.webApplicationManifestFile: preference],
                                     prefetchedHTML: html, httpHeaders: headers)
            ) { url, _, sentHeaders in
                requests += 1
                XCTAssertEqual(url.absoluteString, "https://origin.example.com/app.webmanifest")
                return .init(response: self.response(url, body: body).response,
                             url: url, httpHeaders: sentHeaders)
            }
            let icons = try await finder.find()
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(icons.map { $0.source.lastPathComponent }, ["first.png", "last.png"])
            for icon in icons { XCTAssertEqual(icon.httpHeaders, headers) }
        }
    }

    func testManifestPreferenceDoesNotInventAManifestRelation() async throws {
        let html = try SwiftSoup.parse("""
            <head><link rel='preferred.png' href='/wrong.json'>
            <link rel='notmanifest' href='/also-wrong.json'></head>
            """)
        var requests = 0
        let finder = WebApplicationManifestFaviconFinder(url: source,
            configuration: .init(preferences: [.webApplicationManifestFile: "preferred.png"],
                                 prefetchedHTML: html)
        ) { url, _, _ in
            requests += 1
            return .init(response: self.response(url, body: #"{"icons":[{"src":"preferred.png"}]}"#).response,
                         url: url, httpHeaders: nil)
        }
        do {
            _ = try await finder.find()
            XCTFail("An icon filename is not a manifest link relation")
        } catch {
            guard case FaviconError.failedToFindWebApplicationManifestFile = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(requests, 0)
    }

    func testManifestKeepsUsableIconsAmongMalformedMembers() async throws {
        let html = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
        let finalURL = URL(string: "https://cdn.example.net/manifests/app.webmanifest")!
        let body = """
            {"icons":[null,7,"invalid",[],{},{"src":false},
            {"src":"file:///tmp/icon.png"},{"src":"https://user:password@origin.example.com/icon.png"},
            {"src":"first.png","sizes":"16x16"},{"src":"preferred.png"},{"src":"last.png"}]}
            """
        var requests = 0
        let finder = WebApplicationManifestFaviconFinder(url: source,
            configuration: .init(preferences: [.webApplicationManifestFile: "preferred.png"],
                                 prefetchedHTML: html, httpHeaders: headers)
        ) { _, _, sentHeaders in
            requests += 1
            XCTAssertEqual(sentHeaders, self.headers)
            return .init(response: self.response(finalURL, body: body).response,
                         url: finalURL, httpHeaders: ["Accept-Language": "ja"])
        }
        let icons = try await finder.find()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(icons.map { $0.source.absoluteString }, [
            "https://cdn.example.net/manifests/preferred.png",
            "https://cdn.example.net/manifests/first.png",
            "https://cdn.example.net/manifests/last.png"
        ])
        XCTAssertEqual(icons[1].size, FaviconSize(width: 16, height: 16))
        for icon in icons { XCTAssertEqual(icon.httpHeaders, ["Accept-Language": "ja"]) }
    }

    func testManifestWithoutUsableIconsThrowsInsteadOfReturningEmptySuccess() async throws {
        let html = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
        let bodies = [
            #"{"icons":[]}"#,
            #"{"icons":[{},{"src":""},{"src":"  "},{"src":7}]}"#,
            #"{"icons":[{"src":"file:///tmp/icon.png"},{"src":"data:image/png;base64,AA=="},{"src":"https://user:password@origin.example.com/icon.png"}]}"#,
            #"{"icons":[null,7,"invalid",[]]}"#,
            #"{"icons":{}}"#,
            #"{}"#
        ]
        for body in bodies {
            var requests = 0
            let finder = WebApplicationManifestFaviconFinder(url: source,
                configuration: .init(prefetchedHTML: html)
            ) { url, _, _ in
                requests += 1
                return .init(response: self.response(url, body: body).response,
                             url: url, httpHeaders: nil)
            }
            do {
                _ = try await finder.find()
                XCTFail("A manifest without usable icons must permit the caller to try another source")
            } catch {
                guard case FaviconError.webApplicationManifestFileConainedNoIcons = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(requests, 1)
        }
    }

    func testManifestChoosesLargestValidDeclaredSize() async throws {
        let html = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
        let cases: [(String, FaviconSize)] = [
            ("16x16 32x32 24x24", FaviconSize(width: 32, height: 32)),
            ("  any\t48X48\n16x16 ", FaviconSize(width: 48, height: 48)),
            ("64x16 40x40", FaviconSize(width: 40, height: 40)),
            ("bad 0x8 -1x2 1.5x2 1e3x2 ２x２ 32x32x32 8x8", FaviconSize(width: 8, height: 8)),
            ("16x16", FaviconSize(width: 16, height: 16))
        ]
        for (sizes, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["icons": [["src": "icon.png", "sizes": sizes]]])
            let body = try XCTUnwrap(String(data: data, encoding: .utf8))
            let finder = WebApplicationManifestFaviconFinder(url: source,
                configuration: .init(prefetchedHTML: html, httpHeaders: headers)
            ) { url, _, sentHeaders in
                .init(response: self.response(url, body: body).response,
                      url: url, httpHeaders: sentHeaders)
            }
            let icons = try await finder.find()
            XCTAssertEqual(icons.count, 1)
            let icon = try XCTUnwrap(icons.first)
            XCTAssertEqual(icon.size, expected, sizes)
            XCTAssertEqual(icon.source.absoluteString, "https://origin.example.com/icon.png")
            XCTAssertEqual(icon.httpHeaders, headers)
        }
    }

    func testManifestKeepsIconsWithoutValidFiniteSizeMetadata() async throws {
        let html = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
        let hugeDimension = String(repeating: "9", count: 400)
        let overflowingAreaDimension = String(repeating: "9", count: 200)
        let sizes: [Any] = [
            NSNull(), 16, "", "any", "0x16", "-1x16", "1.5x2", "NaNx2", "Infinityx2",
            "1e3x2", "x16", "16x", "２x２",
            "\(hugeDimension)x1", "\(overflowingAreaDimension)x\(overflowingAreaDimension)"
        ]
        var entries: [[String: Any]] = sizes.enumerated().map { offset, size in
            ["src": "icon-\(offset).png", "sizes": size]
        }
        entries.append(["src": "no-size.png"])
        let data = try JSONSerialization.data(withJSONObject: ["icons": entries])
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        let finder = WebApplicationManifestFaviconFinder(url: source,
            configuration: .init(prefetchedHTML: html)
        ) { url, _, _ in
            .init(response: self.response(url, body: body).response, url: url, httpHeaders: nil)
        }
        let icons = try await finder.find()
        XCTAssertEqual(icons.count, entries.count)
        XCTAssertEqual(icons.map { $0.source.lastPathComponent },
                       entries.compactMap { $0["src"] as? String })
        XCTAssertTrue(icons.allSatisfy { $0.size == nil })
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

