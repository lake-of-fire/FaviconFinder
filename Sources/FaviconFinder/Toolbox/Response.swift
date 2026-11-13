//
//  Response.swift
//  FaviconFinder
//
//  Created by William Lumley on 20/2/2024.
//

import Foundation

#if os(Linux)
import AsyncHTTPClient
import FoundationNetworking
import NIOCore
import NIOHTTP1
#endif

/// The Response struct is designed to wrap around the raw HTTP response data and provide a consistent way to
/// handle responses across platforms (both Linux and Apple).
/// It abstracts away platform-specific differences, like text encoding and response handling, making it easier to
/// work with HTTP responses in a cross-platform manner.
///
struct Response: Sendable {
    struct RequestContext: Sendable {
        let httpHeaders: [String: String?]?
    }

    // MARK: - Properties

    /// Stores the raw response data.
    let data: Data

    /// The text encoding used in the response, defaulting to UTF-8 if not specified.
    let textEncoding: String.Encoding

    /// The final response URL, when exposed by the platform transport.
    let url: URL?
    /// Nil means unknown; a present context with empty headers must stay empty.
    let requestContext: RequestContext?

    init(data: Data, url: URL?, textEncoding: String.Encoding = .utf8, requestContext: RequestContext? = nil) {
        self.data = data
        self.url = url
        self.textEncoding = textEncoding
        self.requestContext = requestContext
    }

    // MARK: - Lifecycle

#if os(Linux)

    /// Initializes the `Response` object with raw response data and headers on Linux.
    ///
    /// - Parameter rawResponse: A tuple containing the response `Data` and `HTTPHeaders`.
    ///
    init(_ rawResponse: (Data, HTTPHeaders)) {
        self.data = rawResponse.0
        // AsyncHTTPClient's response used here does not carry a final URL.
        self.url = nil
        self.requestContext = nil

        let responseHeaders = rawResponse.1
        guard let contentType = responseHeaders["content-type"].first else {
            self.textEncoding = .utf8
            return
        }

        guard let range = contentType.range(of: "charset=") else {
            self.textEncoding = .utf8
            return
        }

        let rawCharset = contentType[range.upperBound...]
        self.textEncoding = String(rawCharset).encoding
    }

#else

    /// Initializes the `Response` object with raw response data and a `URLResponse` on Apple platforms.
    ///
    /// - Parameter rawResponse: A tuple containing the response `Data` and `URLResponse`.
    ///
    init(_ rawResponse: (Data, URLResponse)) {
        self.data = rawResponse.0
        self.url = rawResponse.1.url
        self.textEncoding = rawResponse.1.encoding
        self.requestContext = nil
    }

#endif

}

// MARK: - String

/// The extension on String provides a method to convert a charset string (e.g., utf-8, iso-8859-1) into a
/// String.Encoding value.
/// This is important for handling various text encodings across platforms, especially on Linux where
/// NSStringEncoding is not available.
///
private extension String {

    /// We need to manually convert our string to String.Encoding
    /// on Linux due to the toll-free bridging from Obj-C to CF classes
    /// is something that's only available on Apple platforms.
    ///
    /// - Returns: The String.Encoding enum that our string represents. Will
    /// return .utf8 is no known equivalent is found.
    /// 
    var encoding: String.Encoding {
        switch self {
        case "us-ascii":
            return .ascii
        case "x-nextstep", "nextstep":
            return .nextstep
        case "euc-jp":
            return .japaneseEUC
        case "utf-8":
            return .utf8
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "symbol":
            return .symbol
        case "non-lossy-ascii":
            return .nonLossyASCII
        case "shift_jis", "cp932":
            return .shiftJIS
        case "iso-8859-2", "latin2":
            return .isoLatin2
        case "unicode":
            return .unicode
        case "windows-1251":
            return .windowsCP1251
        case "windows-1252":
            return .windowsCP1252
        case "windows-1253":
            return .windowsCP1253
        case "windows-1254":
            return .windowsCP1254
        case "windows-1250":
            return .windowsCP1250
        case "iso-2022-jp":
            return .iso2022JP
        case "macroman", "x-mac-roman":
            return .macOSRoman
        case "utf-16", "unicodefffe":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        case "utf-32":
            return .utf32
        case "utf-32be":
            return .utf32BigEndian
        case "utf-32le":
            return .utf32LittleEndian
        default:
            return .utf8
        }
    }
}
