//
//  FaviconFinder.swift
//  FaviconFinder
//
//  Created by William Lumley on 16/10/19.
//  Copyright © 2019 William Lumley. All rights reserved.
//

import Foundation

/// `FaviconFinder` is responsible for locating favicons from a given website URL.
///
/// It manages the process of searching for favicons across different sources such as HTML, raw files,
/// and Web Application Manifest files.
public final class FaviconFinder: @unchecked Sendable {

    // MARK: - Properties

    /// The URL of the site we're trying to extract the Favicon from.
    private let url: URL

    /// Configuration object containing preferences and settings for the favicon search.
    private let configuration: FaviconFinder.Configuration

    /// The current task used to fetch favicon URLs. Can be cancelled if needed.
    private var currentTask: Task<[FaviconURL], Error>?

    // MARK: - Lifecycle

    /// Initializes a new instance of `FaviconFinder`.
    ///
    /// - Parameters:
    ///   - url: The URL of the website where the favicon will be searched for.
    ///   - configuration: The configuration settings for the search. Defaults to `.defaultConfiguration`.
    ///
    public init(
        url: URL,
        configuration: FaviconFinder.Configuration = .defaultConfiguration
    ) {
        self.url = url
        self.configuration = configuration
    }

}

// MARK: - Public

public extension FaviconFinder {

    /// Initiates the search for favicon URLs using available sources.
    ///
    /// - Important: If the user has set a source preference in the configuration,
    /// that source will be prioritized first.
    ///
    /// - Returns: An array of `FaviconURL` instances representing the locations of the favicons found.
    ///
    /// - Throws: Throws a `FaviconError.failedToFindFavicon` if no favicons could be found.
    /// - Throws: A `CancellationError` if the task is cancelled by the user.
    ///
    func fetchFaviconURLs() async throws -> [FaviconURL] {
        try Task.checkCancellation()
        // Cancel any previous task
        self.cancel()

        // Copy configuration and url for outside of the Task
        let config = self.configuration
        let url = self.url

        // Create a new task for fetching favicon URLs
        let search = Task {
            try Task.checkCancellation()
            // All of the sources we'll use to search for our favicon
            // Get the users preferred source and move it to the front of the queue
            let preferredSource = config.preferredSource

            // If this is a mock run, just do that
            if preferredSource == .mock {
                let finder = preferredSource.finder(url: url, configuration: config)
                let favicons = try await finder.find()
                try Task.checkCancellation()
                return favicons
            }

            let sources = FaviconSourceType.allCases.movingElementToFront(preferredSource)

            // Iterate through each source, trying to find the favicon
            // in each source until we find it.
            for source in sources {
                try Task.checkCancellation()
                print("Using source: [\(source)]")
                do {
                    let finder = source.finder(url: url, configuration: config)
                    let faviconURLs = try await finder.find()
                    try Task.checkCancellation()
                    return faviconURLs
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as NSError).isCancelled {
                        throw CancellationError()
                    }
                    print("Failed to find Favicon [\(error)]. Trying next source type.")
                }
            }

            try Task.checkCancellation()
            throw FaviconError.failedToFindFavicon
        }
        self.currentTask = search

        // The mutable slot may already hold a different operation on cancellation.
        return try await withTaskCancellationHandler {
            do {
                let favicons = try await search.value
                try Task.checkCancellation()
                return favicons
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            search.cancel()
        }
    }

    /// Cancels the current favicon fetching task if one is active.
    func cancel() {
        self.currentTask?.cancel()
    }

}

// MARK: - NSError

private extension NSError {

    /// Checks if the error represents a cancellation.
    var isCancelled: Bool {
        self.code == NSURLErrorCancelled
    }

}
