import Foundation
import SwiftSoup
import Testing
@testable import FaviconFinder

private actor ManifestTransportFixture {
    struct Request: Sendable {
        let url: URL
        let checksMetaRefresh: Bool
        let headers: [String: String?]?
    }

    private let replies: [URL: Response]
    private var requests = [Request]()

    init(_ replies: [URL: Response]) { self.replies = replies }

    func fetch(_ url: URL, _ metaRefresh: Bool, _ headers: [String: String?]?) throws -> Response {
        requests.append(Request(url: url, checksMetaRefresh: metaRefresh, headers: headers))
        guard let response = replies[url] else { throw URLError(.badURL) }
        return response
    }

    func recordedRequests() -> [Request] { requests }
}

struct WebApplicationManifestFinderTests {
    private func response(_ body: String, at url: URL?) -> Response {
        Response(data: Data(body.utf8), url: url)
    }

    @Test func manifestUsesActualPageAndManifestURLsAndAcceptsOrdinaryIcons() async throws {
        let page = URL(string: "https://example.com/start")!
        let finalPage = URL(string: "https://example.com/news/index.html")!
        let manifestRequest = URL(string: "https://example.com/assets/app/site.webmanifest")!
        let finalManifest = URL(string: "https://example.com/releases/v2/site.webmanifest")!
        let fixture = ManifestTransportFixture([
            page: response("<head><base href='../assets/'><link rel='alternate MANIFEST' href=' app/site.webmanifest '></head>", at: finalPage),
            manifestRequest: response("""
                {"icons":[
                  {"src":" icons/custom-512.png ","sizes":"48x48 512x512","purpose":"any","extra":true},
                  {"src":"../plain.svg","type":"image/svg+xml"},
                  {"src":"//cdn.example.com/icon.png","sizes":"any"},
                  {"src":"/root.png","sizes":"invalid 0x4 -2x3"},
                  {"src":42}, false,
                  {"src":"launcher-icon-4x.png","sizes":"192x192"}
                ]}
                """, at: finalManifest)
        ])
        let finder = WebApplicationManifestFaviconFinder(url: page, configuration: .init(
            preferredSource: .webApplicationManifestFile,
            preferences: [.webApplicationManifestFile: "launcher-icon-4x.png"],
            checkForMetaRefreshRedirect: true
        ), transport: { try await fixture.fetch($0, $1, $2) })
        let icons = try await finder.find()
        #expect(icons.count == 5)
        #expect(icons.first?.source.absoluteString == "https://example.com/releases/v2/launcher-icon-4x.png")
        #expect(icons.first?.format == .launcherIcon4x)
        let ordinary = try #require(icons.first(where: { $0.source.lastPathComponent == "custom-512.png" }))
        #expect(ordinary.format == .icon)
        #expect(ordinary.size?.width == 512)
        #expect(ordinary.size?.height == 512)
        #expect(icons.contains(where: { $0.source.absoluteString == "https://example.com/releases/plain.svg" && $0.size == nil }))
        #expect(icons.contains(where: { $0.source.absoluteString == "https://cdn.example.com/icon.png" && $0.size == nil }))
        #expect(icons.contains(where: { $0.source.absoluteString == "https://example.com/root.png" && $0.size == nil }))
        let largest = try await icons.largest()
        #expect(largest.source == ordinary.source)
        let requests = await fixture.recordedRequests()
        #expect(requests.map(\.url) == [page, manifestRequest])
        #expect(requests.first?.checksMetaRefresh == true)
    }

    @Test func credentialsRemainFilteredAcrossPageManifestAndIconOrigins() async throws {
        let original = URL(string: "https://private.example/start")!
        let page = URL(string: "https://public.example/landing/index.html")!
        let manifest = URL(string: "https://public.example/landing/site.webmanifest")!
        let finalManifest = URL(string: "https://cdn.example/releases/site.webmanifest")!
        let headers: [String: String?] = [
            "Authorization": "TEST_ONLY", "cOoKiE": "TEST_ONLY",
            "Proxy-Authorization": "TEST_ONLY", "Accept-Language": "ja"
        ]
        let fixture = ManifestTransportFixture([
            original: response("<head><link rel='manifest' href='site.webmanifest'></head>", at: page),
            manifest: response("{\"icons\":[{\"src\":\"https://private.example/icon.png\"},{\"src\":\"icon.png\"}]}", at: finalManifest)
        ])
        let finder = WebApplicationManifestFaviconFinder(url: original, configuration: .init(httpHeaders: headers),
            transport: { try await fixture.fetch($0, $1, $2) })
        let icons = try await finder.find()
        let requests = await fixture.recordedRequests()
        #expect(requests.first?.headers?["Authorization"] == "TEST_ONLY")
        #expect(requests.last?.headers?.count == 1)
        #expect(requests.last?.headers?["Accept-Language"] == "ja")
        for icon in icons {
            #expect(icon.httpHeaders?.count == 1)
            #expect(icon.httpHeaders?["Accept-Language"] == "ja")
        }
    }

    @Test func prefetchedHTMLUsesManifestBaseAndPreservesSameOriginHeaders() async throws {
        let page = URL(string: "https://example.com/articles/current")!
        let manifest = URL(string: "https://example.com/site/app.webmanifest")!
        let document = try SwiftSoup.parse("<head><link rel='manifest' href='/site/app.webmanifest'></head>")
        let fixture = ManifestTransportFixture([
            manifest: response("{\"icons\":[{\"src\":\"icons/plain.png\"}]}", at: nil)
        ])
        let finder = WebApplicationManifestFaviconFinder(url: page, configuration: .init(
            prefetchedHTML: document, httpHeaders: ["Authorization": "TEST_ONLY"]
        ), transport: { try await fixture.fetch($0, $1, $2) })
        let icons = try await finder.find()
        let icon = try #require(icons.first)
        #expect(icon.source.absoluteString == "https://example.com/site/icons/plain.png")
        #expect(icon.size == nil)
        #expect(icon.httpHeaders?["Authorization"] == "TEST_ONLY")
        let requests = await fixture.recordedRequests()
        #expect(requests.map(\.url) == [manifest])
    }

    @Test func eachManifestAndIconOriginBoundaryFiltersCredentialsIndependently() async throws {
        let page = URL(string: "https://private.example/page")!
        for boundary in ["manifest-link", "manifest-response", "icon"] {
            let manifest = URL(string: boundary == "manifest-link"
                ? "https://cdn.example/app.webmanifest" : "https://private.example/app.webmanifest")!
            let finalManifest = boundary == "manifest-response"
                ? URL(string: "https://cdn.example/release/app.webmanifest")! : manifest
            // Returning to the original origin must not restore credentials
            // already removed while obtaining the manifest.
            let icon = boundary == "icon" ? "https://cdn.example/icon.png" : "https://private.example/icon.png"
            let fixture = ManifestTransportFixture([
                page: response("<head><link rel='manifest' href='\(manifest.absoluteString)'></head>", at: page),
                manifest: response("{\"icons\":[{\"src\":\"\(icon)\"}]}", at: finalManifest)
            ])
            let finder = WebApplicationManifestFaviconFinder(url: page, configuration: .init(httpHeaders: [
                "Authorization": "TEST_ONLY", "Cookie": "TEST_ONLY", "Accept-Language": "ja"
            ]), transport: { try await fixture.fetch($0, $1, $2) })
            let icons = try await finder.find()
            let requests = await fixture.recordedRequests()
            #expect(requests.last?.headers?.count == (boundary == "manifest-link" ? 1 : 3))
            let result = try #require(icons.first)
            #expect(result.httpHeaders?.count == 1)
            #expect(result.httpHeaders?["Accept-Language"] == "ja")
        }
    }

    @Test func explicitMetaRefreshHeaderEvidenceSurvivesReturnToOriginalOrigin() async throws {
        let page = URL(string: "https://private.example/page")!
        let manifest = URL(string: "https://private.example/app.webmanifest")!
        let foreign = URL(string: "https://public.example/redirect")!
        let headers: [String: String?] = ["Authorization": "TEST_ONLY", "Cookie": "TEST_ONLY"]
        for boundary in ["page", "manifest"] {
            let requestedURL = boundary == "page" ? page : manifest
            // Use the transport's production response-metadata boundary for
            // the cross-origin response and the subsequent explicit request
            // returning to A. The final URL alone cannot describe this loss.
            let crossOrigin = FaviconURLSession.preservingRequestHeaders(
                in: response("", at: foreign), sentTo: requestedURL, httpHeaders: headers
            )
            let surviving = try #require(crossOrigin.requestContext)
            #expect(surviving.httpHeaders?.isEmpty == true)
            let pageBody = "<head><link rel='manifest' href='/app.webmanifest'></head>"
            let manifestBody = "{\"icons\":[{\"src\":\"/icon.png\"}]}"
            let returned = FaviconURLSession.preservingRequestHeaders(
                in: response(boundary == "page" ? pageBody : manifestBody, at: requestedURL),
                sentTo: requestedURL, httpHeaders: surviving.httpHeaders
            )
            let fixture = ManifestTransportFixture([
                page: boundary == "page" ? returned : response(pageBody, at: page),
                manifest: boundary == "manifest" ? returned : response(manifestBody, at: manifest)
            ])
            let finder = WebApplicationManifestFaviconFinder(url: page, configuration: .init(httpHeaders: headers),
                transport: { try await fixture.fetch($0, $1, $2) })
            let icons = try await finder.find()
            let icon = try #require(icons.first)
            #expect(icon.httpHeaders?.isEmpty == true)
            let requests = await fixture.recordedRequests()
            if boundary == "page" { #expect(requests.last?.headers?.isEmpty == true) }
        }
    }

    @Test func knownAbsentRequestHeadersNeverFallBackToConfigurationCredentials() async throws {
        let page = URL(string: "https://example.com/page")!
        let manifest = URL(string: "https://example.com/app.webmanifest")!
        let knownHeaderSets: [[String: String?]?] = [nil, [:]]
        for knownHeaders in knownHeaderSets {
            let returned = FaviconURLSession.preservingRequestHeaders(
                in: response("{\"icons\":[{\"src\":\"/icon.png\"}]}", at: manifest),
                sentTo: manifest, httpHeaders: knownHeaders
            )
            let fixture = ManifestTransportFixture([manifest: returned])
            let finder = WebApplicationManifestFaviconFinder(url: page, configuration: .init(
                prefetchedHTML: try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>"),
                httpHeaders: ["Authorization": "TEST_ONLY"]
            ), transport: { try await fixture.fetch($0, $1, $2) })
            let icon = try #require(try await finder.find().first)
            #expect(icon.httpHeaders?.isEmpty ?? true)
        }
    }

#if !os(Linux)
    @Test func appleResponseRetainsTransportFinalURL() {
        let finalURL = URL(string: "https://cdn.example/redirected/app.webmanifest")!
        let raw = URLResponse(url: finalURL, mimeType: "application/manifest+json", expectedContentLength: 0, textEncodingName: "utf-8")
        let wrapped = Response((Data(), raw))
        #expect(wrapped.url == finalURL)
        #expect(wrapped.textEncoding == .utf8)
    }
#endif

    @Test func unusableManifestThrowsInsteadOfEndingSourceFallbackWithEmptySuccess() async throws {
        for body in ["{}", "{\"icons\":[]}", "{\"icons\":[false,{\"src\":42},{\"src\":\" \"}]}"] {
            let page = URL(string: "https://example.com/page")!
            let manifest = URL(string: "https://example.com/app.webmanifest")!
            let document = try SwiftSoup.parse("<head><link rel='manifest' href='/app.webmanifest'></head>")
            let fixture = ManifestTransportFixture([manifest: response(body, at: manifest)])
            let finder = WebApplicationManifestFaviconFinder(url: page, configuration: .init(prefetchedHTML: document),
                transport: { try await fixture.fetch($0, $1, $2) })
            do {
                _ = try await finder.find()
                Issue.record("An unusable manifest must fail so the next source can run")
            } catch FaviconError.webApplicationManifestFileConainedNoIcons {
            }
        }
    }
}
