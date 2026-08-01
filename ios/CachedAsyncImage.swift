import SwiftUI

// MARK: - CachedAsyncImage
// Drop-in replacement for AsyncImage (phase-based) that caches images to URLCache.
// First load fetches from network and caches to disk. Subsequent loads are instant.

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (AsyncImagePhase) -> Content
    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { phase = .empty; return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        if let cached = URLCache.shared.cachedResponse(for: request),
           let image = UIImage(data: cached.data) {
            phase = .success(Image(uiImage: image))
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let image = UIImage(data: data) else { phase = .empty; return }
            URLCache.shared.storeCachedResponse(
                CachedURLResponse(response: response, data: data),
                for: URLRequest(url: url)
            )
            phase = .success(Image(uiImage: image))
        } catch {
            phase = .failure(error)
        }
    }
}
