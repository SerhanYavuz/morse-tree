import SwiftUI
import WebKit
import AVFoundation

@main
struct MorseTreeApp: App {
    init() {
        // Play tones even on silent, and allow the microphone for push-to-talk.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            MorseWebView()
                .ignoresSafeArea()
                .background(Color(red: 0.047, green: 0.051, blue: 0.043))
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}

struct MorseWebView: UIViewRepresentable {
    static let storeKey = "morsetree.store"

    func makeCoordinator() -> Coordinator { Coordinator() }


    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true

        let controller = WKUserContentController()
        let saved = UserDefaults.standard.string(forKey: Self.storeKey) ?? "{}"
        #if targetEnvironment(macCatalyst)
        let catalyst = "true"
        #else
        let catalyst = "false"
        #endif
        // Screenshot mode for App Store images: launch with `-shot <scene>` (learn, key, quiz, gloss, text, radio).
        var shot = "null"
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-shot"), i + 1 < args.count,
           args[i + 1].allSatisfy({ $0.isLetter }) { shot = "'\(args[i + 1])'" }
        let inject = WKUserScript(source: "window.__STORE = \(saved); window.__CATALYST = \(catalyst); window.__SHOT = \(shot);",
                                  injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(inject)
        controller.add(context.coordinator, name: "haptic")
        controller.add(context.coordinator, name: "store")
        controller.add(context.coordinator, name: "radio")
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.047, green: 0.051, blue: 0.043, alpha: 1)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        context.coordinator.radio.webView = web
        context.coordinator.webView = web

        // Mouse keying: right clicks never reach the page as pointer events in the Mac app,
        // so catch them natively and hand them to the keyer as a dash.
        let right = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.rightClick(_:)))
        right.buttonMaskRequired = .secondary
        right.cancelsTouchesInView = false
        right.delegate = context.coordinator
        web.addGestureRecognizer(right)

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, UIGestureRecognizerDelegate {
        weak var webView: WKWebView?
        private let light = UIImpactFeedbackGenerator(style: .light)
        private let notify = UINotificationFeedbackGenerator()
        let radio = RadioManager()

        @objc func rightClick(_ g: UITapGestureRecognizer) {
            guard let web = webView else { return }
            let p = g.location(in: web)
            web.evaluateJavaScript("window.__mouseKey && window.__mouseKey('-', \(p.x), \(p.y))")
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "haptic":
                switch message.body as? String {
                case "success": notify.notificationOccurred(.success)
                case "error": notify.notificationOccurred(.error)
                default: light.impactOccurred()
                }
            case "store":
                if let json = message.body as? String {
                    UserDefaults.standard.set(json, forKey: MorseWebView.storeKey)
                }
            case "radio":
                radio.handle(message.body)
            default: break
            }
        }
    }
}
