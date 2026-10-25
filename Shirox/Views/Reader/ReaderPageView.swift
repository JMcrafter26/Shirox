#if os(iOS)
import SwiftUI
import Kingfisher

/// A single manga page: Kingfisher-loaded, aspect-fit, with a placeholder
/// while loading, a few tries of its own (``ReaderPageRetry``), and then a tap-to-retry
/// error state. `referer` is the SOURCE
/// SITE's origin (not the image host) — manga CDNs hotlink-protect against it.
struct ReaderPageView: View {
    let urlString: String
    let referer: String
    let pageNumber: Int
    /// The height this page occupied last time it was laid out, when known. Reserving it keeps
    /// a re-created page from briefly claiming the 2:3 placeholder size and shoving everything
    /// below it — the jump that made scrolling back up teleport between pages.
    var knownHeight: CGFloat? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    /// Shared Kingfisher pipeline for reader pages (also used by the
    /// next-chapter prefetch warmer — MUST stay identical or the cache keys
    /// won't match). Downsamples to screen width and decodes off-main:
    /// manga pages are often 2-3x larger than needed, and decoding them
    /// full-size on the main thread stutters fast/auto scrolling.
    static func imageOptions(referer: String, for url: URL) -> KingfisherOptionsInfo {
        let cookieHeader = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let bypassUA = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        let reqHeaders = KingfisherImageCache.headers(
            for: url, cookieHeader: cookieHeader, bypassUserAgent: bypassUA,
            refererOverride: referer)
        let modifier = AnyModifier { request in
            var mutable = request
            for (key, value) in reqHeaders { mutable.setValue(value, forHTTPHeaderField: key) }
            return mutable
        }
        let screen = UIScreen.main.bounds
        // Generous height headroom so tall webtoon strips keep their detail.
        let target = CGSize(width: screen.width, height: screen.width * 6)
        return [
            .requestModifier(modifier),
            .processor(DownsamplingImageProcessor(size: target)),
            .scaleFactor(UIScreen.main.scale),
            .backgroundDecode,
            .cacheOriginalImage,
        ]
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .contextMenu { pageMenu(image) }
            } else if failed {
                VStack(spacing: 8) {
                    IconView("exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("reader.page_failed_to_load \(pageNumber)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("reader.tap_to_retry")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .modifier(ReaderPagePlaceholderSize(knownHeight: knownHeight))
                .contentShape(Rectangle())
                .onTapGesture {
                    failed = false
                    attempt += 1
                }
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView()
                        .tint(.white.opacity(0.6))
                }
                .modifier(ReaderPagePlaceholderSize(knownHeight: knownHeight))
            }
        }
        .task(id: "\(urlString)#\(attempt)") { await load() }
    }

    @ViewBuilder
    private func pageMenu(_ shown: UIImage) -> some View {
        Button {
            Task { await saveToPhotos(fallback: shown) }
        } label: {
            Label("reader.save_to_photos", icon: "photo.on.rectangle")
        }
        if #available(iOS 16.0, *) {
            let image = Image(uiImage: shown)
            ShareLink(item: image, preview: SharePreview(String(localized: "reader.page \(pageNumber)"), image: image)) {
                Label("profile.share", icon: "square.and.arrow.up")
            }
        }
    }

    /// Saves the page at full resolution — the original Kingfisher kept on disk
    /// (`.cacheOriginalImage`), or the file itself for downloaded chapters — rather than
    /// the screen-width copy on display.
    @MainActor
    private func saveToPhotos(fallback: UIImage) async {
        let full = await originalImage() ?? fallback
        PhotoLibrarySaver.save(full) { outcome in
            switch outcome {
            case .savedToAlbum:
                ToastManager.shared.show(message: String(localized: "reader.page_saved_to_the_shirox"), type: .success)
            case .savedToLibrary:
                ToastManager.shared.show(message: String(localized: "reader.page_saved_to_photos"), type: .success)
            case .denied:
                ToastManager.shared.show(message: String(localized: "reader.allow_photos_access_in_settings"), type: .warning)
            case .failed(let error):
                ToastManager.shared.show(message: String(localized: "reader.couldnt_save_page \(error.localizedDescription)"), type: .error)
            }
        }
    }

    private func originalImage() async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        if url.isFileURL { return UIImage(contentsOfFile: url.path) }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            ImageCache.default.retrieveImage(forKey: urlString) { result in
                cont.resume(returning: try? result.get().image)
            }
        }
    }

    @MainActor
    private func load() async {
        guard let url = URL(string: urlString) else {
            failed = true
            return
        }
        let options = Self.imageOptions(referer: referer, for: url)
        // Options-aware lookup: the downsampling processor is part of the key.
        if let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: urlString, options: options) {
            image = cached
            return
        }
        let source = KingfisherImageCache.source(for: url, cacheKey: urlString)
        var failures = 0
        while true {
            let result: UIImage? = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                KingfisherManager.shared.retrieveImage(with: source, options: options) {
                    cont.resume(returning: try? $0.get().image)
                }
            }
            if let result {
                image = result
                return
            }
            failures += 1
            // Scrolled away (the task is cancelled with the page): stop trying.
            guard let delay = ReaderPageRetry.delay(afterFailure: failures), !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
        }
        if !Task.isCancelled { failed = true }
    }
}


/// Sizes a not-yet-decoded page: its remembered height when we have one, else the 2:3 guess.
private struct ReaderPagePlaceholderSize: ViewModifier {
    let knownHeight: CGFloat?

    func body(content: Content) -> some View {
        if let knownHeight, knownHeight > 1 {
            content.frame(height: knownHeight)
        } else {
            content.aspectRatio(2/3, contentMode: .fit)
        }
    }
}
#endif
