//
//  HTMLFaviconFinder.swift
//  Pods
//
//  Created by William Lumley on 26/5/21.
//

import Foundation
import SwiftSoup

/// `WebApplicationManifestFaviconFinder` is responsible for finding favicons defined in
/// the web application manifest file of a website. It conforms to the `FaviconFinderProtocol`
/// and searches for icons specified in the "icons" array within the manifest JSON file.
///
/// This class first looks for a `<link rel="manifest">` tag in the HTML document, which points
/// to the web application manifest file. After retrieving the manifest, it parses the file
/// to extract favicon information.
///
/// Use the `find()` method to start searching for favicons in the web application manifest.
///
/// - Note: This class also supports handling meta-refresh redirects if enabled in the configuration.
///
final class WebApplicationManifestFaviconFinder: FaviconFinderProtocol {
    typealias Transport = @Sendable (URL, Bool, [String: String?]?) async throws -> Response
    private let transport: Transport

    // MARK: - Types

    /// A structure representing a reference to the web application manifest file found in the HTML document.
    ///
    /// - `baseURL`: The base URL of the manifest file.
    /// - `rel`: The "rel" attribute value of the manifest tag (typically "manifest").
    /// - `href`: The URL path to the manifest file.
    ///
    struct ManifestFileReference {
        let baseURL: URL
        let rel: String
        let href: String
    }

    // MARK: - Properties

    /// The URL of the website for which the web application manifest favicons are being searched.
    var url: URL

    /// Configuration options for customizing the favicon search, including preferences
    /// for which favicon types to search for and whether meta-refresh redirects should be handled.
    var configuration: FaviconFinder.Configuration

    /// An optional preferred icon source, independent of the manifest link relation.
    var preferredType: String {
        self.configuration.preferences[.webApplicationManifestFile] ?? ""
    }

    // MARK: - FaviconFinder

    /// Initializes a `WebApplicationManifestFaviconFinder` instance.
    ///
    /// - Parameters:
    ///   - url: The URL of the website to search for favicons in the web application manifest.
    ///   - configuration: A configuration object that contains user preferences and options.
    ///
    /// - Returns: A new `WebApplicationManifestFaviconFinder` instance.
    ///
    required init(url: URL, configuration: FaviconFinder.Configuration) {
        self.url = url
        self.configuration = configuration
        self.transport = { url, checkMetaRefresh, headers in
            try await FaviconURLSession.dataTask(
                with: url, checkForMetaRefreshRedirect: checkMetaRefresh, httpHeaders: headers
            )
        }
    }

    init(url: URL, configuration: FaviconFinder.Configuration, transport: @escaping Transport) {
        self.url = url
        self.configuration = configuration
        self.transport = transport
    }

    /// Finds favicons by looking for the web application manifest file in the HTML `<link>` tags.
    ///
    /// This method searches for a `<link rel="manifest">` tag in the HTML document to
    /// retrieve the manifest file. It then extracts favicon information from the manifest's
    /// "icons" array, returning an array of `FaviconURL` instances.
    ///
    /// - Throws:
    ///   - `FaviconError.failedToFindWebApplicationManifestFile` if the manifest file cannot be found.
    ///   - `FaviconError.failedToDownloadWebApplicationManifestFile` if the manifest file cannot be downloaded.
    ///   - `FaviconError.failedToParseWebApplicationManifestFile` if the manifest file cannot be parsed.
    ///   - `FaviconError.webApplicationManifestFileConainedNoIcons` if the manifest file contains no icons.
    ///
    /// - Returns: An array of `FaviconURL` instances representing the favicons found in the manifest file.
    ///
    func find() async throws -> [FaviconURL] {
        let html: Document
        var pageURL = url
        var survivingHeaders = configuration.httpHeaders

        if let prefetchedHTML = configuration.prefetchedHTML {
            html = prefetchedHTML
        } else {
            // Download the web page at our URL
            let response = try await transport(
                self.url, self.configuration.checkForMetaRefreshRedirect, survivingHeaders
            )
            pageURL = response.url ?? url
            if let requestContext = response.requestContext {
                survivingHeaders = requestContext.httpHeaders
            }
            survivingHeaders = FaviconURLSession.headersForMetaRefreshRedirect(
                survivingHeaders, from: url, to: pageURL
            )

            let data = response.data

            // Make sure we can parse the response into a string
            guard let htmlStr = String(data: data, encoding: response.textEncoding) else {
                throw FaviconError.failedToParseHTML
            }

            // Turn our HTML string as an XML document we can check out
            html = try SwiftSoup.parse(htmlStr)
        }

        // Get just the head of our HTML document
        guard let head = html.head() else {
            throw FaviconError.failedToParseHtmlHead
        }

        // Get a hold of a reference to our Manifest File
        guard let manifestFileReference = try self.manifestFileReference(from: head, pageURL: pageURL) else {
            throw FaviconError.failedToFindWebApplicationManifestFile
        }

        // Download the manifest file
        survivingHeaders = FaviconURLSession.headersForMetaRefreshRedirect(
            survivingHeaders, from: pageURL, to: manifestFileReference.baseURL
        )
        let response = try await transport(manifestFileReference.baseURL, false, survivingHeaders)
        let manifestURL = response.url ?? manifestFileReference.baseURL
        if let requestContext = response.requestContext {
            survivingHeaders = requestContext.httpHeaders
        }
        survivingHeaders = FaviconURLSession.headersForMetaRefreshRedirect(
            survivingHeaders, from: manifestFileReference.baseURL, to: manifestURL
        )
        let manifestData: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw FaviconError.failedToParseWebApplicationManifestFile
            }
            manifestData = parsed
        } catch {
            throw FaviconError.failedToParseWebApplicationManifestFile
        }

        // Grab our "icons" data
        guard let rawIcons = manifestData["icons"] as? [Any] else {
            throw FaviconError.webApplicationManifestFileConainedNoIcons
        }

        // And turn it into something we can work with
        var faviconURLs = rawIcons.compactMap { value -> FaviconURL? in
            guard let rawIcon = value as? [String: Any],
                  let rawSource = rawIcon["src"] as? String else {
                return nil
            }
            let sourceString = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceString.isEmpty,
                  let source = URL(string: sourceString, relativeTo: manifestURL)?.absoluteURL else {
                return nil
            }
            return FaviconURL(
                source: source,
                format: FaviconFormatType(rawValue: sourceString) ?? .icon,
                sourceType: .webApplicationManifestFile,
                size: Self.largestDeclaredSize(rawIcon["sizes"] as? String),
                httpHeaders: FaviconURLSession.headersForMetaRefreshRedirect(
                    survivingHeaders, from: manifestURL, to: source
                )
            )
        }
        guard !faviconURLs.isEmpty else {
            throw FaviconError.webApplicationManifestFileConainedNoIcons
        }
        if !preferredType.isEmpty,
           let preferredURL = URL(string: preferredType, relativeTo: manifestURL)?.absoluteURL,
           let index = faviconURLs.firstIndex(where: { $0.source == preferredURL }) {
            faviconURLs.insert(faviconURLs.remove(at: index), at: 0)
        }
        return faviconURLs
    }

}

// MARK: - Private

private extension WebApplicationManifestFaviconFinder {

    /// Searches the provided HTML head element for a `<link>` tag that references the manifest file.
    ///
    /// - Parameter htmlHead: The HTML head element to parse for the manifest file reference.
    ///
    /// - Throws: Throws an error if there is an issue parsing the HTML head.
    ///
    /// - Returns: A `ManifestFileReference` object containing the data found in the "manifest" tag.
    ///
    func manifestFileReference(from htmlHead: Element, pageURL: URL) throws -> ManifestFileReference? {
        let manifestFileAttr = try htmlHead.select("link").first {
            try $0.attr("rel").split(whereSeparator: { $0.isWhitespace })
                .contains(where: { $0.lowercased() == "manifest" })
        }

        guard let manifestFileAttr else {
            return nil
        }
        let rel = try manifestFileAttr.attr("rel")
        let href = try manifestFileAttr.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty,
              let baseURL = href.baseUrl(from: htmlHead, from: pageURL)?.absoluteURL else {
            return nil
        }

        return ManifestFileReference(baseURL: baseURL, rel: rel, href: href)
    }

    static func largestDeclaredSize(_ sizes: String?) -> FaviconSize? {
        sizes?.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> FaviconSize? in
            let dimensions = token.lowercased().split(separator: "x", omittingEmptySubsequences: false)
            guard dimensions.count == 2,
                  dimensions.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
                  let width = Double(dimensions[0]), let height = Double(dimensions[1]),
                  width > 0, height > 0, width.isFinite, height.isFinite,
                  (width * height).isFinite else { return nil }
            return FaviconSize(width: width, height: height)
        }.max(by: { $0.dimension < $1.dimension })
    }

}
