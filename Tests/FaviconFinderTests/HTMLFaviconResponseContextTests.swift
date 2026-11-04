import Foundation
import SwiftSoup
import Testing
@testable import FaviconFinder

struct HTMLFaviconResponseContextTests {
    @Test func linksAndMetadataResolveFromActualPageAndHTMLBase() async throws {
        let requested = URL(string: "https://example.com/start")!
        let finalPage = URL(string: "https://example.com/news/index.html")!
        let body = """
            <head><base href='../assets/'>
            <link rel='apple-touch-icon' href='icons/apple.png' sizes='180x180'>
            <link rel='icon' href='https://cdn.example/favicon.png'>
            <meta property='og:image' content='../social.jpg'>
            </head>
            """
        let response = Response(data: Data(body.utf8), url: finalPage)
        let finder = HTMLFaviconFinder(url: requested, configuration: .init(
            checkForMetaRefreshRedirect: true,
            httpHeaders: ["Authorization": "TEST_ONLY", "Accept-Language": "ja"],
            acceptHeaderImage: true
        ), transport: { url, checksMetaRefresh, headers in
            #expect(url == requested)
            #expect(checksMetaRefresh)
            #expect(headers?["Authorization"] == "TEST_ONLY")
            return response
        })

        let icons = try await finder.find()
        try #require(icons.count == 3)
        #expect(icons.map(\.source.absoluteString) == [
            "https://example.com/assets/icons/apple.png",
            "https://cdn.example/favicon.png",
            "https://example.com/social.jpg"
        ])
        #expect(icons.map(\.format) == [.appleTouchIcon, .icon, .metaOpenGraphImage])
        #expect(icons.first?.size == FaviconSize(width: 180, height: 180))
        #expect(icons.first?.httpHeaders?["Authorization"] == "TEST_ONLY")
        #expect(icons[1].httpHeaders?.count == 1)
        #expect(icons[1].httpHeaders?["Accept-Language"] == "ja")
        #expect(icons.last?.httpHeaders?["Authorization"] == "TEST_ONLY")
    }

    @Test func redirectedPageCannotRestoreCredentialsForIconsOnOriginalOrigin() async throws {
        let requested = URL(string: "https://private.example/start")!
        let finalPage = URL(string: "https://public.example/news/index.html")!
        let body = """
            <head><link rel='icon' href='https://private.example/icon.png'>
            <meta property='og:image' content='https://private.example/social.png'></head>
            """
        let headers: [String: String?] = [
            "Authorization": "TEST_ONLY", "Cookie": "TEST_ONLY", "Accept-Language": "ja"
        ]
        for hasTransportContext in [false, true] {
            let rawResponse = Response(data: Data(body.utf8), url: finalPage)
            let response = hasTransportContext
                ? FaviconURLSession.preservingRequestHeaders(
                    in: rawResponse, sentTo: requested, httpHeaders: headers)
                : rawResponse
            let finder = HTMLFaviconFinder(url: requested, configuration: .init(
                httpHeaders: headers, acceptHeaderImage: true
            ), transport: { _, _, _ in response })
            let icons = try await finder.find()
            #expect(icons.count == 2)
            for icon in icons {
                #expect(icon.httpHeaders?.count == 1)
                #expect(icon.httpHeaders?["Accept-Language"] == "ja")
            }
        }
    }

    @Test func knownAbsentHeadersStayAbsentAfterReturningToOriginalOrigin() async throws {
        let page = URL(string: "https://example.com/page")!
        let body = "<head><link rel='icon' href='/icon.png'></head>"
        let knownHeaders: [[String: String?]?] = [nil, [:]]
        for headers in knownHeaders {
            let response = Response(data: Data(body.utf8), url: page,
                requestContext: .init(httpHeaders: headers))
            let finder = HTMLFaviconFinder(url: page, configuration: .init(
                httpHeaders: ["Authorization": "TEST_ONLY"]
            ), transport: { _, _, _ in response })
            let icons = try await finder.find()
            let icon = try #require(icons.first)
            #expect(icon.httpHeaders == headers)
        }
    }

    @Test func prefetchedAndUnknownResponseURLsKeepRequestedBaseAndHeaderPolicy() async throws {
        let page = URL(string: "https://example.com/news/index.html")!
        let body = """
            <head><link rel='icon' href='icons/icon.png'>
            <meta property='og:image' content='/header.jpg'></head>
            """
        for prefetched in [false, true] {
            let response = Response(data: Data(body.utf8), url: nil)
            let document: Document?
            if prefetched {
                document = try SwiftSoup.parse(body)
            } else {
                document = nil
            }
            let finder = HTMLFaviconFinder(url: page, configuration: .init(
                prefetchedHTML: document,
                httpHeaders: ["Authorization": "TEST_ONLY"]
            ), transport: { _, _, _ in
                #expect(!prefetched)
                return response
            })
            let icons = try await finder.find()
            #expect(icons.count == 1, "Header images still require explicit opt-in")
            let icon = try #require(icons.first)
            #expect(icon.source.absoluteString == "https://example.com/news/icons/icon.png")
            #expect(icon.httpHeaders?["Authorization"] == "TEST_ONLY")
        }
    }
}
