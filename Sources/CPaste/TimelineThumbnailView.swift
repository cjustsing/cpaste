import CPasteCore
import CoreGraphics
import Foundation
import SwiftUI

actor TimelineThumbnailCache {
    static let shared = TimelineThumbnailCache()
    static let cardMaxPixelSize = 1_024
    static let inspectorMaxPixelSize = 1_536

    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init(totalCostLimit: Int = 128 * 1_024 * 1_024) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = 256
    }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let pixelSize = normalizedPixelSize(maxPixelSize)
        let key = cacheKey(for: url, maxPixelSize: pixelSize)
        let cacheKey = key as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task.detached(priority: .userInitiated) {
            ImageThumbnailDecoder.thumbnail(at: url, maxPixelSize: pixelSize)
        }
        inFlight[key] = task

        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        }
        return image
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
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasFinishedLoading {
                failureContent()
            } else {
                Color.clear
            }
        }
        .task(id: requestID) {
            thumbnail = nil
            hasFinishedLoading = false
            let loadedImage = await TimelineThumbnailCache.shared.thumbnail(
                for: imageURL,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else {
                return
            }
            thumbnail = loadedImage
            hasFinishedLoading = true
        }
    }

    private var requestID: String {
        "\(imageURL.standardizedFileURL.path)#\(maxPixelSize)"
    }
}
