import AppKit
@preconcurrency import WebKit

enum MusicProviderWebLoginError: Error, LocalizedError {
    case unsupportedProvider
    case alreadyPresenting
    case cancelled
    case pageLoadFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "这个音乐服务暂不支持网页登录。"
        case .alreadyPresenting:
            "已有登录窗口打开。"
        case .cancelled:
            "已取消登录。"
        case .pageLoadFailed:
            "官方登录页加载失败，请检查网络后重试。"
        }
    }
}

@MainActor
protocol MusicProviderWebAuthenticating: AnyObject {
    func login(providerID: MusicProviderID) async throws -> String
    func clearSession(providerID: MusicProviderID) async
}

extension MusicProviderWebAuthenticating {
    func clearSession(providerID: MusicProviderID) async {}
}

@MainActor
final class MusicProviderWebLoginController: MusicProviderWebAuthenticating {
    private var activeSession: MusicProviderWebLoginSession?
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore = .default()) { self.dataStore = dataStore }
    func cancel() { activeSession?.cancel() }

    func login(providerID: MusicProviderID) async throws -> String {
        guard activeSession == nil else {
            throw MusicProviderWebLoginError.alreadyPresenting
        }
        guard let url = MusicProviderWebLoginPolicy.loginURL(for: providerID) else {
            throw MusicProviderWebLoginError.unsupportedProvider
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = MusicProviderWebLoginSession(
                providerID: providerID,
                url: url,
                dataStore: dataStore
            ) { [weak self] result in
                self?.activeSession = nil
                continuation.resume(with: result)
            }
            activeSession = session
            session.start()
        }
    }

    func clearSession(providerID: MusicProviderID) async {
        let cookieStore = dataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies where MusicProviderWebLoginPolicy.includes(
            cookie,
            for: providerID
        ) {
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }
}

@MainActor
private final class MusicProviderWebLoginSession:
    NSObject,
    NSWindowDelegate,
    WKNavigationDelegate,
    WKUIDelegate
{
    private let providerID: MusicProviderID
    private let initialURL: URL
    private let completion: (Result<String, Error>) -> Void
    private let cookieStore: WKHTTPCookieStore
    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var isFinished = false
    private let dataStore: WKWebsiteDataStore

    init(
        providerID: MusicProviderID,
        url: URL,
        dataStore: WKWebsiteDataStore,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        self.providerID = providerID
        initialURL = url
        self.dataStore = dataStore
        self.completion = completion
        cookieStore = dataStore.httpCookieStore
        super.init()
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        self.webView = webView

        let statusLabel = NSTextField(
            labelWithString: "请在官方页面扫码登录，成功后窗口会自动关闭"
        )
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)

        let statusStack = NSStackView(views: [progress, statusLabel])
        statusStack.orientation = .horizontal
        statusStack.spacing = 8
        statusStack.edgeInsets = NSEdgeInsets(
            top: 10,
            left: 14,
            bottom: 10,
            right: 14
        )

        let contentView = NSView()
        contentView.addSubview(statusStack)
        contentView.addSubview(webView)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            statusStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: statusStack.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 940, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(providerName)登录"
        window.minSize = CGSize(width: 760, height: 580)
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        pollTimer = Timer.scheduledTimer(
            timeInterval: 1.2,
            target: self,
            selector: #selector(pollCookies),
            userInfo: nil,
            repeats: true
        )
        webView.load(URLRequest(url: initialURL))
        pollCookies()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isFinished else {
            return
        }
        pollTimer?.invalidate()
        readCookieHeader { [weak self] header in
            guard let self, !self.isFinished else {
                return
            }
            if let header {
                self.finish(.success(header), closeWindow: false)
            } else {
                self.finish(
                    .failure(MusicProviderWebLoginError.cancelled),
                    closeWindow: false
                )
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }
        if url.scheme == "about" {
            return .allow
        }
        if MusicProviderWebLoginPolicy.allowsInAppNavigation(
            url,
            for: providerID
        ) {
            return .allow
        }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url
        else {
            return nil
        }
        if MusicProviderWebLoginPolicy.allowsInAppNavigation(
            url,
            for: providerID
        ) {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        pollCookies()
        clickVisibleLoginControl(in: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        guard !isFinished else {
            return
        }
        finish(.failure(MusicProviderWebLoginError.pageLoadFailed))
    }

    @objc
    private func pollCookies() {
        readCookieHeader { [weak self] header in
            guard let self, let header, !self.isFinished else {
                return
            }
            self.finish(.success(header))
        }
    }

    private func readCookieHeader(
        completion: @escaping (String?) -> Void
    ) {
        cookieStore.getAllCookies { [providerID] cookies in
            completion(
                MusicProviderWebLoginPolicy.cookieHeader(
                    for: providerID,
                    cookies: cookies
                )
            )
        }
    }

    private func clickVisibleLoginControl(in webView: WKWebView) {
        let script = """
        setTimeout(() => {
          const candidates = Array.from(
            document.querySelectorAll('a, button, [role="button"]')
          );
          const target = candidates.find((node) => {
            const text = (node.textContent || '').trim();
            const rect = node.getBoundingClientRect();
            return /登录|登陆/.test(text) && rect.width > 0 && rect.height > 0;
          });
          if (target) target.click();
        }, 700);
        """
        webView.evaluateJavaScript(script)
    }

    func cancel() { finish(.failure(MusicProviderWebLoginError.cancelled)) }

    private func finish(
        _ result: Result<String, Error>,
        closeWindow: Bool = true
    ) {
        guard !isFinished else {
            return
        }
        isFinished = true
        pollTimer?.invalidate()
        pollTimer = nil
        completion(result)
        if closeWindow {
            window?.close()
        }
        window = nil
        webView = nil
    }

    private var providerName: String {
        switch providerID {
        case .netease:
            "网易云音乐"
        case .qqMusic:
            "QQ 音乐"
        default:
            "音乐服务"
        }
    }
}
