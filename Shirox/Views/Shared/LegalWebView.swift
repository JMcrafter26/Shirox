import SwiftUI

#if os(tvOS)
    import FakeWebKit
#else
    import WebKit
#endif

enum LegalPage {
    case imprint, privacy, contributors, licenses

    var title: String {
        switch self {
        case .imprint:      return "Imprint"
        case .privacy:      return "Data Privacy"
        case .contributors: return "Contributors"
        case .licenses:     return "Licenses"
        }
    }

    private var filename: String {
        switch self {
        case .imprint:      return "imprint.html"
        case .privacy:      return "privacy.html"
        case .contributors: return "contributors.html"
        case .licenses:     return "licenses.html"
        }
    }

    var url: URL? {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "GithubRepo") as? String,
              !repo.isEmpty else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(repo)/refs/heads/main/docs/legal/\(filename)")
    }
}

struct LegalWebView: View {
    let page: LegalPage
    @State private var html: String?
    @State private var failed = false
    @State private var transitionDone = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.slash")
            } else if transitionDone {
                _WebViewBridge(html: html, baseURL: page.url)
                    .ignoresSafeArea()
                    .overlay { if html == nil { ProgressView() } }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(page.title)

        #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
        #elseif os(iOS)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
        #endif

        .task {
            // Wait for the push animation to finish before touching WKWebView or the network.
            // This keeps the transition smooth — WKWebView init blocks the main thread on first use.
            try? await Task.sleep(nanoseconds: 400_000_000)
            transitionDone = true

            guard let url = page.url else { failed = true; return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                html = String(data: data, encoding: .utf8) ?? ""
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - Platform bridges

#if os(macOS)
private struct _WebViewBridge: NSViewRepresentable {
    let html: String?
    let baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let html, !context.coordinator.hasLoaded else { return }
        context.coordinator.hasLoaded = true
        nsView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var hasLoaded = false

        // Tapped links open in the default browser instead of inside the page.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}
#else
private struct _WebViewBridge: UIViewRepresentable {
    let html: String?
    let baseURL: URL?

    let config = WKWebViewConfiguration()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: config)
        #if !os(tvOS)
            wv.isOpaque = false
            wv.backgroundColor = .systemGroupedBackground
            wv.scrollView.backgroundColor = .systemGroupedBackground
            wv.scrollView.contentInsetAdjustmentBehavior = .always
            wv.navigationDelegate = context.coordinator
        #endif
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let html, !context.coordinator.hasLoaded else { return }
        context.coordinator.hasLoaded = true
        uiView.loadHTMLString(html, baseURL: baseURL)
    }

    #if os(tvOS)
    final class Coordinator { var hasLoaded = false }
    #else
    final class Coordinator: NSObject, WKNavigationDelegate {
        var hasLoaded = false

        // Tapped links open in Safari instead of inside the page.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
    #endif
}
#endif
