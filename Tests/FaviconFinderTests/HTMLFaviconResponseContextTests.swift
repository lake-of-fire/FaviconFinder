import Foundation
import SwiftSoup
import Testing
@testable import FaviconFinder

struct HTMLFaviconResponseContextTests {
    @Test func HTMLSizeListsKeepLargestUsableDimensions() {
        let page = URL(string: "https://example.com/icon.png")!
        let cases: [(String?, FaviconSize?)] = [
            ("16x16 512x512", FaviconSize(width: 512, height: 512)),
            ("512x512 16x16", FaviconSize(width: 512, height: 512)),
            ("\t16X16\n128x64\r\u{0C}32x32 ", FaviconSize(width: 128, height: 64)),
            ("any 32x32 64X64", FaviconSize(width: 64, height: 64)),
            ("bad 16xx16 0x1024 -1x1024 NaNx16 infx16 32x32", FaviconSize(width: 32, height: 32)),
            ("1e308x1e308 32x32", FaviconSize(width: 32, height: 32)),
            ("100.50x20.02", FaviconSize(width: 100.50, height: 20.02)),
            ("any", nil), ("ANY", nil), ("", nil), (nil, nil),
            ("16xx16", nil), ("x16", nil), ("16x", nil),
            ("0x16 -1x16 NaNx16 infx16", nil),
            ("16x16\u{00A0}512x512", nil),
            ("16x16\u{0B}512x512", nil)
        ]
        for (sizes, expected) in cases {
            let icon = FaviconURL(source: page, format: .icon, sourceType: .html, htmlSizeTag: sizes)
            #expect(icon.size == expected, "Unexpected size for \(sizes ?? "<nil>")")
        }
    }

    @Test func HTMLFinderLargestSelectsMultiSizeIconForFetchedAndPrefetchedPages() async throws {
        let requested = URL(string: "https://example.com/start")!
        let finalPage = URL(string: "https://example.com/news/index.html")!
        let body = """
            <head><base href='../assets/'>
            <link rel='icon' href='multi.ico' sizes='16x16&#9;512X512'>
            <link rel='apple-touch-icon' href='single.png' sizes='256x256'>
            <link rel='icon' href='scalable.svg' sizes='any'>
            </head>
            """
        for prefetched in [false, true] {
            let document: Document? = prefetched ? try SwiftSoup.parse(body) : nil
            let finder = HTMLFaviconFinder(url: requested, configuration: .init(
                prefetchedHTML: document, httpHeaders: ["Authorization": "TEST_ONLY"]
            ), transport: { url, _, headers in
                #expect(!prefetched, "Prefetched HTML must not invoke transport")
                #expect(url == requested)
                #expect(headers?["Authorization"] == "TEST_ONLY")
                return Response(data: Data(body.utf8), url: finalPage)
            })
            let icons = try await finder.find()
            #expect(icons.count == 3)
            #expect(icons.map(\.size) == [
                FaviconSize(width: 512, height: 512), FaviconSize(width: 256, height: 256), nil
            ])
            let largest = try await icons.largest()
            #expect(largest.source.absoluteString == "https://example.com/assets/multi.ico")
            #expect(largest.httpHeaders?["Authorization"] == "TEST_ONLY")
        }
    }

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

    @Test func iconRelationsUseASCIICaseAndWhitespaceTokensForPrefetchedAndFetchedHTML() async throws {
        let requested = URL(string: "https://example.com/start")!
        let finalPage = URL(string: "https://example.com/news/index.html")!
        let relations: [(String, FaviconFormatType)] = [
            ("ICON", .icon),
            ("  icon&#9;", .icon),
            ("alternate&#9;IcOn&#10;stylesheet", .icon),
            ("&#12;icon&#13;", .icon),
            ("SHORTCUT ICON", .shortcutIcon),
            ("shortcut&#9;icon", .icon),
            ("APPLE-TOUCH-ICON", .appleTouchIcon),
            ("alternate APPLE-TOUCH-ICON-PRECOMPOSED", .appleTouchIconPrecomposed)
        ]
        let links = relations.enumerated().map { index, relation in
            "<link rel='\(relation.0)' href='icon\(index).png' sizes='32x32'>"
        }.joined()
        let body = "<head><base href='../assets/'>\(links)</head>"
        for prefetched in [false, true] {
            let document: Document?
            if prefetched {
                document = try SwiftSoup.parse(body)
            } else {
                document = nil
            }
            let finder = HTMLFaviconFinder(url: requested, configuration: .init(
                prefetchedHTML: document,
                httpHeaders: ["Authorization": "TEST_ONLY"]
            ), transport: { _, _, _ in
                #expect(!prefetched, "Prefetched HTML must not invoke transport")
                return Response(data: Data(body.utf8), url: finalPage)
            })
            let icons = try await finder.find()
            #expect(icons.map(\.format) == relations.map(\.1))
            #expect(icons.map(\.source.absoluteString) == relations.indices.map {
                "https://example.com/assets/icon\($0).png"
            })
            #expect(icons.allSatisfy { $0.size == FaviconSize(width: 32, height: 32) })
            #expect(icons.allSatisfy { $0.httpHeaders?["Authorization"] == "TEST_ONLY" })
        }
    }

    @Test func iconRelationsRejectSubstringsUnicodeWhitespaceAndUnrelatedFormatNames() async throws {
        let page = URL(string: "https://example.com/page")!
        let invalid = [
            "noticon", "iconography", "apple-touch-icon-extra", "shortcut",
            "alternate&#160;icon", "alternate&#11;icon", "&#160;icon",
            "İCON", "og:image", "thumbnail", "ico", "launcher-icon-4x.png"
        ]
        let links = invalid.enumerated().map { index, rel in
            "<link rel='\(rel)' href='/invalid\(index).png'>"
        }.joined()
        let body = "<head>\(links)<link rel='icon icon' href='/valid.png'></head>"
        let finder = HTMLFaviconFinder(url: page, configuration: .init(
            prefetchedHTML: try SwiftSoup.parse(body)
        ))
        let icons = try await finder.find()
        #expect(icons.count == 1, "Only complete HTML icon tokens may yield candidates")
        #expect(icons.first?.source.absoluteString == "https://example.com/valid.png")
        #expect(icons.first?.format == .icon)
    }

    @Test func fetchedRelationTokensRetainRedirectCredentialFilteringAndHeaderImageOptIn() async throws {
        let requested = URL(string: "https://private.example/start")!
        let finalPage = URL(string: "https://public.example/news/index.html")!
        let body = """
            <head><link rel='alternate ICON' href='https://private.example/icon.png'>
            <meta property='og:image' content='https://private.example/social.png'></head>
            """
        for acceptsHeaderImage in [false, true] {
            let finder = HTMLFaviconFinder(url: requested, configuration: .init(
                httpHeaders: ["Authorization": "TEST_ONLY", "Accept-Language": "ja"],
                acceptHeaderImage: acceptsHeaderImage
            ), transport: { _, _, _ in
                Response(data: Data(body.utf8), url: finalPage)
            })
            let icons = try await finder.find()
            #expect(icons.map(\.format) == (acceptsHeaderImage ? [.icon, .metaOpenGraphImage] : [.icon]))
            for icon in icons {
                #expect(icon.httpHeaders?.count == 1)
                #expect(icon.httpHeaders?["Accept-Language"] == "ja")
            }
        }
    }
}
