//
//  ICOFaviconFinder.swift
//  Pods
//
//  Created by William Lumley on 26/5/21.
//

import Foundation

#if os(Linux)
import FoundationNetworking
#endif

class ICOFaviconFinder: FaviconFinderProtocol {

    // MARK: - Properties

    var url: URL
    var preferredType: String
    var checkForMetaRefreshRedirect: Bool

    var logEnabled: Bool
    var description: String
    var logger: Logger?

    // MARK: - FaviconFinder

    required init(url: URL, preferredType: String?, checkForMetaRefreshRedirect: Bool, logEnabled: Bool) {
        self.url = url
        self.preferredType = preferredType ?? "favicon.ico" // Default to the filename of "favicon.ico" if user does not present us with one
        self.checkForMetaRefreshRedirect = checkForMetaRefreshRedirect

        self.logEnabled = logEnabled
        self.description = NSStringFromClass(Self.self)
        if logEnabled {
            self.logger = Logger(faviconFinder: self)
        }
    }

    #if os(Linux)
    func search(onSearchComplete: @escaping OnSearchComplete) {
        let baseUrl = URL(string: "/", relativeTo: self.url)
        guard let faviconUrl = URL(string: self.preferredType, relativeTo: baseUrl) else {
            onSearchComplete(.failure(.failedToFindFavicon))
            return
        }

        // Switch to the background thread, as we'll be doing some networking
        DispatchQueue.global().async {

            // We have the URL, let's see if there's any valid image data here
            if let _ = try? Data(contentsOf: faviconUrl) {
                // We found valid image data, woohoo!
                let faviconURL = FaviconURL(url: faviconUrl, type: .ico)
                onSearchComplete(.success(faviconURL))
            } else {
                // We couldn't find any image, but let's try the root domain (just in case it's hiding there)
                // ie. If we couldn't find the image at "subdomain.google.com/favicon.ico", let's try "google.com/favicon.ico"

                // Create the URL, removing subdomains
                guard let base = self.url.urlWithoutSubdomains?.deletingPathExtension(),
                      let rootURL = URL(string: self.preferredType, relativeTo: base) else {
                    // We couldn't find the image at the root domain, so let's give the user a failure.
                    onSearchComplete(.failure(.failedToFindFavicon))
                    return
                }

                // We created a URL without the subdomains, let's check if there's a valid image there
                if let _ = try? Data(contentsOf: rootURL) {
                    // We found valid image data, woohoo!
                    let faviconURL = FaviconURL(url: rootURL, type: .ico)
                    onSearchComplete(.success(faviconURL))
                } else {
                    // Well we couldn't find any valid image data at the provided URL, nor the root domain, game over.
                    onSearchComplete(.failure(.failedToFindFavicon))
                }
            }
        }
    }
    #else
    func search() async throws -> FaviconURL {
        // If there's not, try the root instead.
        // Then, remove the RootICO finder and type.
        let baseUrl = URL(string: "/", relativeTo: self.url)
        guard let faviconUrl = URL(string: self.preferredType, relativeTo: baseUrl) else {
            throw FaviconError.failedToFindFavicon
        }

        // We have the URL, let's see if there's any valid image data here
        let data = try await FaviconURLRequest.dataTask(with: faviconUrl, checkForMetaRefreshRedirect: self.checkForMetaRefreshRedirect).0
        if FaviconImage(data: data) != nil {
            // We found valid image data, woohoo!
            return FaviconURL(url: faviconUrl, type: .ico)
        } else {
            // We couldn't find any image, but let's try the root domain (just in case it's hiding there)
            // ie. If we couldn't find the image at "subdomain.google.com/favicon.ico", let's try "google.com/favicon.ico"

            // Create the URL, removing subdomains
            guard let base = self.url.urlWithoutSubdomains?.deletingPathExtension(),
                  let rootURL = URL(string: self.preferredType, relativeTo: base) else {
                      // We couldn't find the image at the root domain, so let's give the user a failure.
                      throw FaviconError.failedToFindFavicon
                  }

            // We created a URL without the subdomains, let's check if there's a valid image there
            let data = try await URLSession.shared.data(from: rootURL).0
            if FaviconImage(data: data) != nil {
                // We found valid image data, woohoo!
                return FaviconURL(url: rootURL, type: .ico)
            } else {
                // Well we couldn't find any valid image data at the provided URL, nor the root domain, game over.
                throw FaviconError.failedToFindFavicon
            }
        }
    }
    #endif

}
