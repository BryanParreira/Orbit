import SwiftUI
import WebKit

/// The Windows image Orbit downloads: a link from Microsoft's own download page, plus the
/// SHA-256 hashes that page lists for its images.
struct MicrosoftDownload: Equatable {
    let url: URL
    let hashes: Set<String>

    var fileName: String { url.lastPathComponent }

    /// Only Microsoft's own servers over HTTPS, and only disc images.
    static func accepts(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              host == "microsoft.com" || host.hasSuffix(".microsoft.com") else { return false }
        return url.pathExtension.lowercased() == "iso"
    }
}

/// Microsoft's official Windows 11 on ARM download page, inside Orbit. Microsoft offers no
/// direct link, so the user picks a language and clicks Download as in a browser; Orbit takes
/// the link from there and downloads it itself, with progress and verification.
struct MicrosoftDownloadSheet: View {
    let page: URL
    let onChoose: (MicrosoftDownload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("logo-windows").resizable().scaledToFit().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Windows 11").font(.headline)
                    Text("Choose a language, confirm, then click the 64-bit ARM download. Orbit takes it from there.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            MicrosoftPageView(page: page, isLoading: $isLoading) { download in
                onChoose(download)
                dismiss()
            }
            Divider()
            Label("This is Microsoft's own page (\(page.host ?? "microsoft.com")). Orbit only reads the download link and the checksums Microsoft lists.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 900, height: 680)
    }
}

private struct MicrosoftPageView: NSViewRepresentable {
    let page: URL
    @Binding var isLoading: Bool
    let onDownload: (MicrosoftDownload) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // nothing from this page is kept after the sheet closes
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: page))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MicrosoftPageView
        private var handled = false

        init(_ parent: MicrosoftPageView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, MicrosoftDownload.accepts(url) else { return .allow }
            // the download itself: Orbit fetches it, the page doesn't
            if !handled {
                handled = true
                let hashes = await Self.listedHashes(in: webView)
                parent.onDownload(MicrosoftDownload(url: url, hashes: hashes))
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            // a link that only reveals itself as the ISO after a redirect
            if let url = response.response.url, MicrosoftDownload.accepts(url), !handled {
                handled = true
                parent.onDownload(MicrosoftDownload(url: url, hashes: await Self.listedHashes(in: webView)))
                return .cancel
            }
            return .allow
        }

        /// Links that open a new window (the download button may) load here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, let url = action.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.isLoading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.isLoading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.isLoading = false }

        /// SHA-256 values the page lists for its images ("Verify your download"), hidden ones too.
        private static func listedHashes(in webView: WKWebView) async -> Set<String> {
            guard let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String else { return [] }
            return Set(html.matches(of: /\b[0-9A-Fa-f]{64}\b/).map { String($0.output).lowercased() })
        }
    }
}
