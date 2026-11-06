import CPasteCore
import CoreGraphics
import Foundation
import SwiftUI

actor TimelineThumbnailCache {
    static let shared = TimelineThumbnailCache()
    static let cardMaxPixelSize = 1_024
    static let inspectorMaxPixelSize = 1_536

    private let pipeline: ImageRequestPipeline

    init(totalCostLimit: Int = 128 * 1_024 * 1_024) {
        pipeline = ImageRequestPipeline(maximumConcurrentOperations: 2, totalCostLimit: totalCostLimit)
    }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let pixelSize = normalizedPixelSize(maxPixelSize)
        let key = cacheKey(for: url, maxPixelSize: pixelSize)
        return await pipeline.image(for: key) {
            ImageThumbnailDecoder.thumbnail(at: url, maxPixelSize: pixelSize)
        }
    }

    func prefetch(urls: [URL], maxPixelSize: Int) async {
        for url in urls {
            guard !Task.isCancelled else {
                return
            }
            _ = await thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }

    private func normalizedPixelSize(_ requestedSize: Int) -> Int {
        switch max(1, requestedSize) {
        case ...512:
            return 512
        case ...1_024:
            return 1_024
        default:
            return 1_536
        }
    }

    private func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        "\(url.standardizedFileURL.path)#\(maxPixelSize)"
    }
}

struct TimelineThumbnailView<FailureContent: View>: View {
    let imageURL: URL
    let maxPixelSize: Int
    let contentMode: ContentMode
    private let failureContent: () -> FailureContent

    @State private var thumbnail: CGImage?
    @State private var hasFinishedLoading = false
    @State private var loadedRequestID: String?

    init(
        imageURL: URL,
        maxPixelSize: Int,
        contentMode: ContentMode,
        @ViewBuilder failureContent: @escaping () -> FailureContent
    ) {
        self.imageURL = imageURL
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.failureContent = failureContent
    }

    var body: some View {
        Group {
            if loadedRequestID == requestID, let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loadedRequestID == requestID, hasFinishedLoading {
                failureContent()
            } else {
                Color.clear
            }
        }
        .task(id: requestID) {
            let requestedID = requestID
            thumbnail = nil
            hasFinishedLoading = false
            loadedRequestID = nil
            let loadedImage = await TimelineThumbnailCache.shared.thumbnail(
                for: imageURL,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else {
                return
            }
            thumbnail = loadedImage
            hasFinishedLoading = true
            loadedRequestID = requestedID
        }
    }

    private var requestID: String {
        "\(imageURL.standardizedFileURL.path)#\(maxPixelSize)"
    }
}
