//
//  FaviconURLSession.swift
//  FaviconFinder
//
//  Created by William Lumley on 5/3/2022.
//

#if os(Linux)
import AsyncHTTPClient
import FoundationNetworking
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
#endif

import Foundation
import SwiftSoup

/// The `FaviconURLSession` class wraps `URLSession` to provide consistent behavior for downloading favicons,
/// with support for handling meta-refresh redirects and bridging async functionality
/// for both Apple and Linux platforms.
///
/// - Why a wrapper around `URLSession`?
///   1. **Meta-refresh redirects**: `URLSession` does not handle meta-refresh redirects. This wrapper ensures
///      such redirects are handled appropriately, allowing the caller to ignore such details.
///   2. **Cross-platform support**: On Linux, `FoundationNetworking` doesn't support async/await functionality.
///      This wrapper handles the differences between Apple and Linux platforms, abstracting away the complexity
///      for the caller.
///
/// The `dataTask` function supports HTTP headers and optional checking for meta-refresh redirects.
///
/// - Parameters:
///   - url: The URL to send the request to.
///   - checkForMetaRefreshRedirect: A Boolean indicating whether to check for meta-refresh redirects in the HTML.
///     Defaults to `false`.
///   - httpHeaders: Optional HTTP headers to include in the request.
///
final class FaviconURLSession {

    /// Keep response bodies bounded consistently on Apple and Linux.
    static let maximumResponseBytes = 2 * 1024 * 1024

    /// Downloads data from the provided URL, optionally checking for meta-refresh redirects
    /// and handling cross-platform differences between Apple and Linux.
    ///
    /// - Parameters:
    ///   - url: The URL from which to download the data.
    ///   - checkForMetaRefreshRedirect: A Boolean indicating whether to check for
    ///   meta-refresh redirects in the response.
    ///     Defaults to `false`.
    ///   - httpHeaders: Optional dictionary of HTTP headers to include in the request.
    ///     The keys represent header field names, and the values are their respective values.
    ///
    /// - Returns: A `Response` object containing the data and headers of the response.
    ///
    /// - Throws: Throws if the network request fails or if meta-refresh redirect processing fails.
    ///
    static func dataTask(
        with url: URL,
        checkForMetaRefreshRedirect: Bool = false,
        httpHeaders: [String: String?]? = nil
    ) async throws -> Response {
#if os(Linux)
        try await linuxDataTask(
            with: url,
            checkForMetaRefreshRedirect: checkForMetaRefreshRedirect,
            httpHeaders: httpHeaders
        )
#else
        try await appleDataTask(
            with: url,
            checkForMetaRefreshRedirect: checkForMetaRefreshRedirect,
            httpHeaders: httpHeaders
        )
#endif
    }

}

// MARK: - Private

private extension FaviconURLSession {

#if os(Linux)

    /// Downloads data from the provided URL, optionally checking for meta-refresh redirects
    /// and handling cross-platform differences between Apple and Linux.
    ///
    /// - Parameters:
    ///   - url: The URL from which to download the data.
    ///   - checkForMetaRefreshRedirect: A Boolean indicating whether to check for
    ///   meta-refresh redirects in the response.
    ///     Defaults to `false`.
    ///   - httpHeaders: Optional dictionary of HTTP headers to include in the request.
    ///     The keys represent header field names, and the values are their respective values.
    ///
    /// - Returns: A `Response` object containing the data and headers of the response.
    ///
    /// - Throws: Throws if the network request fails or if meta-refresh redirect processing fails.
    ///
    static func linuxDataTask(
        with url: URL,
        checkForMetaRefreshRedirect: Bool = false,
        httpHeaders: [String: String?]? = nil
    ) async throws -> Response {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer {
            try? httpClient.shutdown()
        }

        // Convert headers to HTTPHeaders
        var headers = HTTPHeaders()
        if let httpHeaders = httpHeaders {
            for (key, value) in httpHeaders {
                if let value {
                    headers.add(name: key, value: value)
                }
            }
        }

        // Create the request
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers = headers

        // Send the request
        let response = try await httpClient.execute(request, timeout: .seconds(15))

        // Collect the response body
        let byteBuffer = try await response.body.collect(upTo: FaviconURLSession.maximumResponseBytes)
        let data = Data(buffer: byteBuffer)

        // Check for meta-refresh redirect if needed
        if checkForMetaRefreshRedirect {
            guard let htmlStr = String(data: data, encoding: .utf8) else {
                throw URLError(.badServerResponse)
            }
            let html = try SwiftSoup.parse(htmlStr)

            if let redirectURL = try Self.metaRefreshURL(in: html, relativeTo: url) {
                return try await linuxDataTask(
                    with: redirectURL,
                    checkForMetaRefreshRedirect: false,
                    httpHeaders: Self.headersForMetaRefreshRedirect(
                        httpHeaders,
                        from: url,
                        to: redirectURL
                    )
                )
            }
        }

        // Return the response with data and headers
        return Response((data, response.headers))
    }

    #else

    /// Downloads data from the provided URL, optionally checking for meta-refresh redirects
    /// and handling cross-platform differences between Apple and Linux.
    ///
    /// - Parameters:
    ///   - url: The URL from which to download the data.
    ///   - checkForMetaRefreshRedirect: A Boolean indicating whether to check for
    ///   meta-refresh redirects in the response.
    ///     Defaults to `false`.
    ///   - httpHeaders: Optional dictionary of HTTP headers to include in the request.
    ///     The keys represent header field names, and the values are their respective values.
    ///
    /// - Returns: A `Response` object containing the data and headers of the response.
    ///
    /// - Throws: Throws if the network request fails or if meta-refresh redirect processing fails.
    static func appleDataTask(
        with url: URL,
        checkForMetaRefreshRedirect: Bool = false,
        httpHeaders: [String: String?]? = nil
    ) async throws -> Response {
        var request = URLRequest(url: url)
        Self.addHeaders(httpHeaders, to: &request)

        let (data, urlResponse) = try await Self.boundedData(for: request)
        let response = Response((data, urlResponse))

        guard checkForMetaRefreshRedirect,
              let htmlString = String(data: data, encoding: response.textEncoding),
              let html = try? SwiftSoup.parse(htmlString),
              let redirectURL = try Self.metaRefreshURL(
                  in: html,
                  relativeTo: urlResponse.url ?? url
              )
        else {
            return response
        }

        var redirectRequest = URLRequest(url: redirectURL)
        Self.addHeaders(
            Self.headersForMetaRefreshRedirect(
                httpHeaders,
                from: url,
                to: redirectURL,
                responseURL: urlResponse.url ?? url
            ),
            to: &redirectRequest
        )
        let redirectResponse = try await Self.boundedData(for: redirectRequest)
        return Response(redirectResponse)
    }

    static func addHeaders(_ httpHeaders: [String: String?]?, to request: inout URLRequest) {
        guard let httpHeaders else {
            return
        }
        for (key, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    /// URLSession's `data(for:)` buffers an unbounded response. AsyncBytes lets us stop after the same limit
    /// used by the Linux implementation, while retaining the response metadata needed for text decoding.
    static func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        var data = Data()
        data.reserveCapacity(Self.maximumResponseBytes)

        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }

        return (data, response)
    }

    #endif

}

extension FaviconURLSession {

    static func headersForMetaRefreshRedirect(
        _ headers: [String: String?]?,
        from sourceURL: URL,
        to destinationURL: URL,
        responseURL: URL? = nil
    ) -> [String: String?]? {
        // Credentials stripped by an HTTP redirect must not be restored by meta refresh.
        if let responseURL {
            let survivingHeaders = headersForMetaRefreshRedirect(headers, from: sourceURL, to: responseURL)
            return headersForMetaRefreshRedirect(survivingHeaders, from: responseURL, to: destinationURL)
        }
        guard let headers else { return nil }

        func effectivePort(_ url: URL) -> Int? {
            if let port = url.port { return port }
            switch url.scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }

        let isSameOrigin = sourceURL.scheme?.lowercased()
                == destinationURL.scheme?.lowercased()
            && sourceURL.host?.lowercased()
                == destinationURL.host?.lowercased()
            && effectivePort(sourceURL) == effectivePort(destinationURL)
        guard !isSameOrigin else { return headers }

        let sensitiveNames = Set([
            "authorization",
            "cookie",
            "proxy-authorization",
        ])
        return headers.filter { key, _ in
            !sensitiveNames.contains(key.lowercased())
        }
    }

    /// Parses and resolves a meta refresh URL using URL's RFC 3986 relative URL rules.
    /// Kept internal so the URL semantics can be tested without making a network request.
    static func metaRefreshURL(in html: Document, relativeTo baseURL: URL) throws -> URL? {
        guard let head = html.head(),
              let element = try head
                  .getElementsByAttribute("http-equiv")
                  .whereAttr("http-equiv", equals: "refresh")
        else {
            return nil
        }

        let content = try element.attr("content")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let separator = content.firstIndex(of: ";")
        else {
            return nil
        }

        let assignment = content[content.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = assignment.firstIndex(of: "="),
              assignment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("url") == .orderedSame else {
            return nil
        }

        let rawURL = assignment[assignment.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let redirectString = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !redirectString.isEmpty else {
            return nil
        }
        return URL(string: redirectString, relativeTo: baseURL)?.absoluteURL
    }
}

// MARK: - SwiftSoup.Elements

/// Filters an array of `Elements` (from SwiftSoup) to find the first element with the specified attribute and value.
private extension Elements {

    /// Finds an attribute that matches the condition in an array of Elements
    ///
    /// - Parameters:
    ///   - attribute: The attribute to search for (e.g., "http-equiv").
    ///   - value: The value the attribute must equal (e.g., "refresh").
    /// - Returns: The first `Element` that matches the attribute and value, or `nil` if no such element is found.
    /// - Throws: Throws an error if an element's attribute cannot be accessed.
    ///
    func whereAttr(_ attribute: String, equals value: String) throws -> Element? {
        for element in self where try element.attr(attribute).caseInsensitiveCompare(value) == .orderedSame {
            return element
        }

        return nil
    }

}
