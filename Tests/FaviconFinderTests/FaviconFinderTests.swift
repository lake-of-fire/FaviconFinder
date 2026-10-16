//
//  FaviconFinderTests.swift
//  FaviconFinderTests
//
//  Created by William Lumley on 16/10/19.
//  Copyright © 2019 William Lumley. All rights reserved.
//

@testable import FaviconFinder
import Foundation
import SwiftSoup
import Testing

struct FaviconFinderTests {

    @Test func icoRequestsAndResultsKeepCredentialsOnTheirOriginOnly() async throws {
        let source = URL(string: "https://tenant.example.com/page")!
        let headers: [String: String?] = [
            "Authorization": "TEST_ONLY", "cOoKiE": "TEST_ONLY",
            "Proxy-Authorization": "TEST_ONLY", "Accept-Language": "ja"
        ]
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6LkAAAAASUVORK5CYII="
        ))
        for (preferred, fallsBack) in [("favicon.ico", false), ("favicon.ico", true),
                                     ("https://icons.example.net/icon.png", false)] {
            let recorder = ICORequestRecorder(image: png, rejectFirst: fallsBack)
            let finder = ICOFaviconFinder(url: source, configuration: .init(
                preferences: [.ico: preferred], httpHeaders: headers
            )) { url, _, headers in
                await recorder.fetch(url: url, headers: headers)
            }
            let icon = try #require(try await finder.find().first)
            let requests = await recorder.requests
            #expect(requests.count == (fallsBack ? 2 : 1))
            for request in requests {
                #expect(request.headers?["Accept-Language"] == "ja")
                if request.url.host == source.host {
                    #expect(request.headers == headers)
                } else {
                    #expect(request.headers?["Authorization"] == nil)
                    #expect(request.headers?["cOoKiE"] == nil)
                    #expect(request.headers?["Proxy-Authorization"] == nil)
                }
            }
            #expect(icon.httpHeaders == requests.last?.headers)
            #expect(icon.source.absoluteURL == requests.last?.url.absoluteURL)
        }
    }

    @Test func discoveredIconsKeepSensitiveHeadersOnTheirOriginOnly() async throws {
        for destination in ["https://origin.invalid/icon.png", "https://other.invalid/icon.png"] {
            let document = try SwiftSoup.parse("<head><link rel='icon' href='\(destination)'></head>")
            let finder = FaviconFinder(url: URL(string: "https://origin.invalid/page")!, configuration: .init(
                preferredSource: .html, prefetchedHTML: document,
                httpHeaders: ["Authorization": "synthetic", "Cookie": "synthetic", "User-Agent": "ReviewTest"]
            ))
            let icon = try #require(try await finder.fetchFaviconURLs().first)
            #expect(icon.httpHeaders?["User-Agent"] == "ReviewTest")
            if icon.source.host == "origin.invalid" {
                #expect(icon.httpHeaders?["Authorization"] == "synthetic")
            } else {
                #expect(icon.httpHeaders?["Authorization"] == nil)
                #expect(icon.httpHeaders?["Cookie"] == nil)
            }
        }
    }

    // MARK: - Tests

    @Test("Test URLs")
    func testURLs() async throws {
        // Remove the URL that requires meta-refresh redirect
        var testURLs = TestURL.allCases
        testURLs.removeAll { $0 == .metaRefreshRedirect }
        testURLs.removeAll { $0 == .nonUtf8Encoded }

        // Iterate over each URL and ensure that they can be fetched
        for url in testURLs {
            print("Fetching \(url)")
            try await self.fetch(url: url.url)
            print("Fetched \(url)")
        }
    }

    @Test("Test ICO Favicon")
    func testIco() async throws {
        let favicon = try await FaviconFinder(
            url: TestURL.google.url,
            configuration: .init(preferredSource: .ico)
        )
            .fetchFaviconURLs()
            .download()
            .first()

        // Ensure that our favicon is actually valid
        let image = try #require(favicon.image)
        #expect(image.isValidImage == true)

        // Ensure that our favicon was retrieved from the desired source
        #expect(favicon.url.sourceType == .ico)
    }

    @Test("Test HTML Favicon")
    func testHtml() async throws {
        let favicon = try await FaviconFinder(
            url: TestURL.w3Schools.url,
            configuration: .init(preferredSource: .html)
        )
            .fetchFaviconURLs()
            .download()
            .first()

        // Ensure that our favicon is actually valid
        let image = try #require(favicon.image)
        #expect(image.isValidImage == true)

        // Ensure that our favicon was retrieved from the desired source
        #expect(favicon.url.sourceType == .html)
    }

    @Test("Test WebApplicationManifestFile Favicon")
    func testWebApplicationManifestFile() async throws {
        let favicon = try await FaviconFinder(
            url: TestURL.webApplicationManifest.url,
            configuration: .init(preferredSource: .webApplicationManifestFile)
        )
            .fetchFaviconURLs()
            .download()
            .first()

        // Ensure that our favicon is actually valid
        let image = try #require(favicon.image)
        #expect(image.isValidImage == true)

        // Ensure that our favicon was retrieved from the desired source
        #expect(favicon.url.sourceType == .webApplicationManifestFile)
    }

    @Test("Test Meta Refresh Redirect Favicon")
    func testCheckForMetaRefreshRedirect() async throws {
        let favicon = try await FaviconFinder(
            url: TestURL.metaRefreshRedirect.url,
            configuration: .init(
                preferredSource: .html,
                checkForMetaRefreshRedirect: true
            )
        )
            .fetchFaviconURLs()
            .download()
            .first()

        // Ensure that our favicon is actually valid
        let image = try #require(favicon.image)
        #expect(image.isValidImage == true)

        // Ensure that our favicon was retrieved from the desired source
        #expect(favicon.url.sourceType == .html)
    }

    @Test("Test ForeignEncoding Favicon")
    func testForeignEncoding() async throws {
        let pageURL = URL(string: "https://shift-jis.example/")!
        let urlResponse = try #require(HTTPURLResponse(
            url: pageURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=Shift_JIS"]
        ))
        let source = "<html><head><title>日本語</title><link rel=\"icon\" href=\"/favicon.ico\"></head></html>"
        let encoded = try #require(source.data(using: .shiftJIS))
        let response = Response((encoded, urlResponse))
        let decoded = try #require(String(data: response.data, encoding: response.textEncoding))
        let document = try SwiftSoup.parse(decoded)
        let title = try document.title()

        let faviconURLs = try await FaviconFinder(
            url: pageURL,
            configuration: .init(
                preferredSource: .html,
                prefetchedHTML: document
            )
        ).fetchFaviconURLs()

        #expect(title == "日本語")
        #expect(faviconURLs.contains {
            $0.source.absoluteURL == URL(string: "https://shift-jis.example/favicon.ico")
        })
    }

    @Test("Resolve relative meta refresh URLs with URL semantics")
    func testRelativeMetaRefreshURL() throws {
        let document = try SwiftSoup.parse(
            "<html><head><meta http-equiv=\"Refresh\" content=\"0; URL=../assets/favicon.ico\"></head></html>"
        )
        let baseURL = try #require(URL(string: "https://catalog.example.com/opds/pages/index.html"))
        let redirectURL = try #require(
            try FaviconURLSession.metaRefreshURL(in: document, relativeTo: baseURL)
        )

        #expect(redirectURL == URL(string: "https://catalog.example.com/opds/assets/favicon.ico"))
    }

    @Test("Strip credentials from cross-origin meta refresh requests")
    func testCrossOriginMetaRefreshHeaders() throws {
        let headers: [String: String?] = [
            "Authorization": "Bearer secret",
            "Cookie": "session=secret",
            "Proxy-Authorization": "Basic secret",
            "Accept-Language": "en",
        ]
        let source = try #require(URL(string: "https://catalog.example.com/page"))
        let crossOrigin = try #require(URL(string: "https://icons.example.net/icon"))
        let sameOrigin = try #require(URL(string: "https://catalog.example.com/icon"))

        let filtered = try #require(FaviconURLSession.headersForMetaRefreshRedirect(
            headers,
            from: source,
            to: crossOrigin
        ))
        #expect(filtered["Authorization"] == nil)
        #expect(filtered["Cookie"] == nil)
        #expect(filtered["Proxy-Authorization"] == nil)
        #expect(filtered["Accept-Language"] == "en")

        #expect(FaviconURLSession.headersForMetaRefreshRedirect(
            headers,
            from: source,
            to: sameOrigin
        ) == headers)
    }

    @Test("HTTP redirects cannot restore credentials on a subsequent meta refresh")
    func testMetaRefreshAfterHTTPRedirect() throws {
        let source = try #require(URL(string: "https://catalog.example.com/page"))
        let landing = try #require(URL(string: "https://icons.example.net/landing"))
        let headers: [String: String?] = [
            "Authorization": "Bearer secret", "Cookie": "session=secret",
            "Proxy-Authorization": "Basic secret", "Accept-Language": "en",
        ]
        for destination in [landing.appendingPathComponent("capture"), source] {
            let filtered = try #require(FaviconURLSession.headersForMetaRefreshRedirect(
                headers, from: source, to: destination, responseURL: landing
            ))
            #expect(filtered == ["Accept-Language": "en"])
        }
        #expect(FaviconURLSession.headersForMetaRefreshRedirect(
            headers, from: source, to: source, responseURL: source
        ) == headers)
    }

    @Test("Test Cancel")
    func testCancel() async throws {
        let faviconFinder = FaviconFinder(
            url: TestURL.google.url,
            configuration: .init(preferredSource: .mock)
        )

        // Find the Favicon's in a separate Task, so we can cancel it
        let fetchTask = Task {
            do {
                _ = try await faviconFinder.fetchFaviconURLs()
                Issue.record("Expected fetchFaviconURLs to be cancelled, but it completed")
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Expected CancellationError, received \(error)")
                return false
            }
        }

        // Wait a moment to ensure the task starts
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Cancel the finding
        faviconFinder.cancel()

        // We got a CancellationError, meaning that we got a cancellation, yay
        #expect(await fetchTask.value)
    }

}

private actor ICORequestRecorder {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String?]?
    }
    let image: Data
    let rejectFirst: Bool
    private(set) var requests: [Request] = []

    init(image: Data, rejectFirst: Bool) {
        self.image = image
        self.rejectFirst = rejectFirst
    }

    func fetch(url: URL, headers: [String: String?]?) -> Data {
        requests.append(Request(url: url, headers: headers))
        return rejectFirst && requests.count == 1 ? Data("not an image".utf8) : image
    }
}

private extension FaviconFinderTests {

    func fetch(url: URL) async throws {
        let favicon = try await FaviconFinder(
            url: url,
            configuration: .init(preferredSource: .ico)
        )
            .fetchFaviconURLs()
            .download()
            .first()

        #expect(favicon.image != nil)
    }

}
