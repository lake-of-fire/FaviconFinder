@testable import FaviconFinder
import Foundation
import SwiftSoup
import Testing
#if os(Linux)
import NIOHTTP1
#endif

struct HTMLFaviconResponseContextTests {
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
            ), fetchDocument: { url, _, headers in
                #expect(!prefetched, "Prefetched HTML must not invoke transport")
                #expect(url == requested)
                return .init(response: loadedResponse(finalPage, body: body).response,
                             url: finalPage, httpHeaders: headers)
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
            ), fetchDocument: { url, checksMetaRefresh, headers in
                try await FaviconURLSession.documentTask(with: url,
                    checkForMetaRefreshRedirect: checksMetaRefresh, httpHeaders: headers
                ) { currentURL, sentHeaders in
                    if currentURL == requested {
                        #expect(sentHeaders?["Authorization"] == "TEST_ONLY")
                        return loadedResponse(currentURL, status: 302,
                                              location: finalPage.absoluteString, body: "")
                    }
                    #expect(currentURL == finalPage)
                    #expect(sentHeaders == ["Accept-Language": "ja"])
                    return loadedResponse(currentURL, body: body)
                }
            })
            let icons = try await finder.find()
            #expect(icons.map(\.format) == (acceptsHeaderImage ? [.icon, .metaOpenGraphImage] : [.icon]))
            for icon in icons {
                #expect(icon.httpHeaders?.count == 1)
                #expect(icon.httpHeaders?["Accept-Language"] == "ja")
            }
        }
    }

    @Test func HTMLSizeListsKeepLargestUsableDimensions() {
        let page = URL(string: "https://example.com/icon.png")!
        let cases: [(String?, FaviconSize?)] = [
            ("16x16 512x512", FaviconSize(width: 512, height: 512)),
            ("512x512 16x16", FaviconSize(width: 512, height: 512)),
            ("64x16 40x40", FaviconSize(width: 40, height: 40)),
            ("\t16X16\n128x64\r\u{0C}32x32 ", FaviconSize(width: 128, height: 64)),
            ("any 32x32 64X64", FaviconSize(width: 64, height: 64)),
            ("bad 16xx16 0x1024 -1x1024 NaNx16 infx16 32x32", FaviconSize(width: 32, height: 32)),
            ("1e308x1e308 32x32", FaviconSize(width: 32, height: 32)),
            ("1e309x1 1x1e309 Infinityx16 32x32", FaviconSize(width: 32, height: 32)),
            ("３２x３２ 32,5x32 32×32 16x16", FaviconSize(width: 16, height: 16)),
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
            ), fetchDocument: { url, _, headers in
                #expect(!prefetched, "Prefetched HTML must not invoke transport")
                #expect(url == requested)
                #expect(headers?["Authorization"] == "TEST_ONLY")
                return .init(response: loadedResponse(finalPage, body: body).response,
                             url: finalPage, httpHeaders: headers)
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

    private func loadedResponse(_ url: URL, status: Int = 200, location: String? = nil,
                                body: String) -> FaviconURLSession.LoadedResponse {
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
