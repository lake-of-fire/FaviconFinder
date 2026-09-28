// Forward port of the v3-hotfix favicon transport. Keep AsyncHTTPClient on Linux
// and URLSession on Apple, but apply one explicit redirect/header policy to both.
import Foundation
import SwiftSoup
#if os(Linux)
import AsyncHTTPClient
import FoundationNetworking
import NIOFoundationCompat
import NIOHTTP1
#endif

final class FaviconURLSession {
    static let maximumResponseBytes = FaviconRequestPolicy.maximumResponseBytes

    struct LoadedResponse {
        let response: Response
        let statusCode: Int
        let location: String?
    }

    /// Relative resources and their headers belong to the final document, not
    /// to the original URL/configuration from before its redirects.
    struct DocumentResponse {
        let response: Response
        let url: URL
        let httpHeaders: [String: String?]?
        var data: Data { response.data }
        var textEncoding: String.Encoding { response.textEncoding }
    }

    typealias Load = (URL, [String: String?]?) async throws -> LoadedResponse

    static func dataTask(
        with url: URL,
        checkForMetaRefreshRedirect: Bool = false,
        httpHeaders: [String: String?]? = nil
    ) async throws -> Response {
        try await documentTask(with: url, checkForMetaRefreshRedirect: checkForMetaRefreshRedirect,
                               httpHeaders: httpHeaders).response
    }

    static func documentTask(
        with url: URL,
        checkForMetaRefreshRedirect: Bool = false,
        httpHeaders: [String: String?]? = nil
    ) async throws -> DocumentResponse {
#if os(Linux)
        // One owned client for the entire chain, retaining connection reuse.
        let client = HTTPClient(eventLoopGroupProvider: .singleton,
                                configuration: .init(redirectConfiguration: .disallow))
        do {
            let result = try await documentTask(with: url,
                checkForMetaRefreshRedirect: checkForMetaRefreshRedirect, httpHeaders: httpHeaders
            ) { url, headers in
                try await load(url, headers, client: client)
            }
            try? await client.shutdown()
            return result
        } catch {
            try? await client.shutdown()
            throw error
        }
#else
        return try await documentTask(with: url, checkForMetaRefreshRedirect: checkForMetaRefreshRedirect,
                                       httpHeaders: httpHeaders, load: load)
#endif
    }

    /// Per-call seams for deterministic tests, without mutable global hooks.
    static func dataTask(
        with url: URL, checkForMetaRefreshRedirect: Bool,
        httpHeaders: [String: String?]?, load: Load
    ) async throws -> Response {
        try await documentTask(with: url, checkForMetaRefreshRedirect: checkForMetaRefreshRedirect,
                               httpHeaders: httpHeaders, load: load).response
    }

    static func documentTask(
        with url: URL, checkForMetaRefreshRedirect: Bool,
        httpHeaders: [String: String?]?, load: Load
    ) async throws -> DocumentResponse {
        var state = try FaviconRedirectState(url: url, httpHeaders: httpHeaders)
        var mayFollowMetaRefresh = checkForMetaRefreshRedirect
        while true {
            try Task.checkCancellation()
            let loaded: LoadedResponse
            do { loaded = try await load(state.url, state.httpHeaders) }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
            if [301, 302, 303, 307, 308].contains(loaded.statusCode), let location = loaded.location {
                guard let destination = FaviconRequestPolicy.redirectURL(location, relativeTo: state.url) else {
                    throw URLError(.unsupportedURL)
                }
                try state.follow(destination)
                continue
            }
            if mayFollowMetaRefresh,
               let text = String(data: loaded.response.data, encoding: loaded.response.textEncoding),
               let html = try? SwiftSoup.parse(text),
               let destination = try metaRefreshURL(in: html, relativeTo: state.url) {
                mayFollowMetaRefresh = false
                try state.follow(destination)
                continue
            }
            return DocumentResponse(response: loaded.response, url: state.url, httpHeaders: state.httpHeaders)
        }
    }

#if os(Linux)
    private static func load(
        _ url: URL, _ httpHeaders: [String: String?]?, client: HTTPClient
    ) async throws -> LoadedResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        for (name, value) in httpHeaders ?? [:] {
            if let value { request.headers.add(name: name, value: value) }
        }
        let response = try await client.execute(request, timeout: .seconds(15))
        let body = try await response.body.collect(upTo: maximumResponseBytes)
        return LoadedResponse(response: Response((Data(buffer: body), response.headers)),
                              statusCode: Int(response.status.code),
                              location: response.headers.first(name: "location"))
    }
#else
    private static func load(_ url: URL, _ httpHeaders: [String: String?]?) async throws -> LoadedResponse {
        var request = URLRequest(url: url)
        for (name, value) in httpHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await boundedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return LoadedResponse(response: Response((data, response)), statusCode: httpResponse.statusCode,
                              location: httpResponse.value(forHTTPHeaderField: "Location"))
    }

    static func boundedData(
        for request: URLRequest,
        session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoAutomaticRedirects())
        defer { bytes.task.cancel() }
        return (try await FaviconRequestPolicy.collect(bytes), response)
    }

    private final class NoAutomaticRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
#endif

    static func headersForMetaRefreshRedirect(
        _ headers: [String: String?]?, from sourceURL: URL, to destinationURL: URL, responseURL: URL? = nil
    ) -> [String: String?]? {
        let surviving = FaviconRequestPolicy.headers(headers, from: sourceURL, to: responseURL ?? sourceURL)
        return FaviconRequestPolicy.headers(surviving, from: responseURL ?? sourceURL, to: destinationURL)
    }

    static func metaRefreshURL(in html: Document, relativeTo baseURL: URL) throws -> URL? {
        guard let head = html.head() else { return nil }
        for element in try head.getElementsByAttribute("http-equiv") {
            if try element.attr("http-equiv").trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("refresh") == .orderedSame {
                return FaviconRequestPolicy.metaRefreshURL(content: try element.attr("content"), relativeTo: baseURL)
            }
        }
        return nil
    }
}
