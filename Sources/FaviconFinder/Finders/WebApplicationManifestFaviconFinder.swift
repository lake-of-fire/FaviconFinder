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

    typealias FetchDocument = (URL, Bool, [String: String?]?) async throws -> FaviconURLSession.DocumentResponse
    private let fetchDocument: FetchDocument

    /// The preferred type for manifest file lookup, which defaults to `"manifest"` if no preference is specified.
    var preferredType: String {
        self.configuration.preferences[.webApplicationManifestFile] ?? "manifest"
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
    required convenience init(url: URL, configuration: FaviconFinder.Configuration) {
        self.init(url: url, configuration: configuration) { url, checkRedirect, headers in
            try await FaviconURLSession.documentTask(with: url,
                checkForMetaRefreshRedirect: checkRedirect, httpHeaders: headers)
        }
    }

    init(url: URL, configuration: FaviconFinder.Configuration, fetchDocument: @escaping FetchDocument) {
        self.url = url
        self.configuration = configuration
        self.fetchDocument = fetchDocument
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
        var documentURL = url
        var documentHeaders = configuration.httpHeaders

        if let prefetchedHTML = configuration.prefetchedHTML {
            html = prefetchedHTML
        } else {
            // Download the web page at our URL
            let response = try await fetchDocument(self.url, self.configuration.checkForMetaRefreshRedirect, self.configuration.httpHeaders)

            documentURL = response.url
            documentHeaders = response.httpHeaders
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
        guard let manifestFileReference = try self.manifestFileReference(from: head, documentURL: documentURL) else {
            throw FaviconError.failedToFindWebApplicationManifestFile
        }

        // Download the manifest file
        let manifest = try await self.downloadManifestFile(
            with: manifestFileReference, documentURL: documentURL, httpHeaders: documentHeaders
        )

        // Grab our "icons" data
        guard let rawIcons = manifest.values["icons"] as? [[String: Any]] else {
            throw FaviconError.webApplicationManifestFileConainedNoIcons
        }

        // And turn it into something we can work with
        let faviconURLs = rawIcons.compactMap { rawIcon -> FaviconURL? in
            guard let rawFormat = rawIcon["src"] as? String else {
                return nil
            }
            // Preserve known legacy format cases, but ordinary manifest src
            // values are URLs, not enum names. Sizes are optional metadata.
            let format = FaviconFormatType(rawValue: rawFormat) ?? .icon
            let sizeTag = rawIcon["sizes"] as? String
            guard let source = FaviconRequestPolicy.redirectURL(rawFormat, relativeTo: manifest.url) else {
                return nil
            }

            return FaviconURL(
                source: source,
                format: format,
                sourceType: .webApplicationManifestFile,
                htmlSizeTag: sizeTag,
                httpHeaders: FaviconURLSession.headersForMetaRefreshRedirect(
                    manifest.httpHeaders, from: manifest.url, to: source
                )
            )
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
    func manifestFileReference(from htmlHead: Element, documentURL: URL) throws -> ManifestFileReference? {
        let manifestFileAttr = try htmlHead.select("link").first {
            try $0.attr("rel") == self.preferredType
        }

        guard let manifestFileAttr else {
            return nil
        }
        let rel = try manifestFileAttr.attr("rel")
        let href = try manifestFileAttr.attr("href")
        guard let baseURL = href.baseUrl(from: htmlHead, from: documentURL) else {
            return nil
        }

        return ManifestFileReference(baseURL: baseURL, rel: rel, href: href)
    }

    /// Downloads and parses the web application manifest file from the provided `ManifestFileReference`.
    ///
    /// - Parameter manifestFileReference: The reference pointing to the web application manifest file.
    ///
    /// - Throws:
    ///   - `FaviconError.failedToDownloadWebApplicationManifestFile` if the manifest file cannot be downloaded.
    ///   - `FaviconError.failedToParseWebApplicationManifestFile` if the manifest file cannot be parsed.
    ///
    /// - Returns: A dictionary representing the parsed manifest file.
    ///
    func downloadManifestFile(
        with reference: ManifestFileReference,
        documentURL: URL,
        httpHeaders: [String: String?]?
    ) async throws -> (values: [String: Any], url: URL, httpHeaders: [String: String?]?) {
        let response = try await fetchDocument(
            reference.baseURL, false, FaviconURLSession.headersForMetaRefreshRedirect(
                httpHeaders, from: documentURL, to: reference.baseURL
            )
        )
        do {
            guard let manifestData = try JSONSerialization.jsonObject(
                with: response.data,
                options: .allowFragments
            ) as? [String: Any] else {
                throw FaviconError.failedToDownloadWebApplicationManifestFile
            }

            return (manifestData, response.url, response.httpHeaders)
        } catch {
            throw FaviconError.failedToParseWebApplicationManifestFile
        }
    }

}
