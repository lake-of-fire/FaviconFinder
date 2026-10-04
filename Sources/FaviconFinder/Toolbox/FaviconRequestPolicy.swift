import Foundation

/// Shared by the Apple and Linux transports. Derived from the v3-hotfix
/// header/meta-refresh policy; no network or HTML parser dependency.
enum FaviconRequestPolicy {
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let maximumRedirects = 10

    static func headers(
        _ headers: [String: String?]?,
        from source: URL,
        to destination: URL
    ) -> [String: String?]? {
        guard let headers else { return nil }
        let populated = headers.filter { $0.value != nil }
        guard !sameOrigin(source, destination) else { return populated }
        // Custom headers can carry credentials too. Only explicitly harmless
        // negotiation headers survive an origin change; never restore originals.
        let portableNames: Set<String> = ["accept", "accept-language", "accept-encoding", "user-agent"]
        return populated.filter { portableNames.contains($0.key.lowercased()) }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        return isHTTPURL(lhs) && isHTTPURL(rhs)
            && lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }

    static func isHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty
            && url.user == nil && url.password == nil
    }

    static func redirectURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              isHTTPURL(url) else { return nil }
        return url
    }

    static func metaRefreshURL(content: String, relativeTo baseURL: URL) -> URL? {
        guard let separator = content.firstIndex(of: ";") else { return nil }
        let assignment = content[content.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = assignment.firstIndex(of: "="),
              assignment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("url") == .orderedSame else { return nil }
        var value = assignment[assignment.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = value.first, quote == "\"" || quote == "'" {
            guard value.count >= 2, value.last == quote else { return nil }
            value = String(value.dropFirst().dropLast())
        }
        return redirectURL(value, relativeTo: baseURL)
    }

    /// Stop before appending the first excess byte, including when Content-Length
    /// is missing or untrustworthy. The caller owns cancelling its transport.
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int = maximumResponseBytes
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes >= 0 else { throw URLError(.dataLengthExceedsMaximum) }
        try Task.checkCancellation()
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

/// Carries only the headers that survived previous hops. In particular A→B→A
/// must not reconstruct A's original credentials from the initial configuration.
struct FaviconRedirectState {
    private(set) var url: URL
    private(set) var httpHeaders: [String: String?]?
    private(set) var followedRedirects = 0

    init(url: URL, httpHeaders: [String: String?]?) throws {
        guard FaviconRequestPolicy.isHTTPURL(url) else { throw URLError(.unsupportedURL) }
        self.url = url.absoluteURL
        self.httpHeaders = FaviconRequestPolicy.headers(httpHeaders, from: url, to: url)
    }

    mutating func follow(_ destination: URL) throws {
        guard FaviconRequestPolicy.isHTTPURL(destination) else { throw URLError(.unsupportedURL) }
        guard followedRedirects < FaviconRequestPolicy.maximumRedirects else {
            throw URLError(.httpTooManyRedirects)
        }
        httpHeaders = FaviconRequestPolicy.headers(httpHeaders, from: url, to: destination)
        url = destination.absoluteURL
        followedRedirects += 1
    }
}
