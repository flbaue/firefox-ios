/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import SnapKit
import UIKit
import WebKit
import SwiftyJSON

protocol FxAContentViewControllerDelegate: AnyObject {
    func contentViewControllerDidSignIn(_ viewController: FxAContentViewController, withFlags: FxALoginFlags)
    func contentViewControllerDidCancel(_ viewController: FxAContentViewController)
}

/**
 * A controller that manages a single web view connected to the Firefox
 * Accounts (Desktop) Sync postMessage interface.
 *
 * The postMessage interface is not really documented, but it is simple
 * enough.  I reverse engineered it from the Desktop Firefox code and the
 * fxa-content-server git repository.
 */
class FxAContentViewController: SettingsContentViewController, WKScriptMessageHandler {
    fileprivate enum RemoteCommand: String {
        case canLinkAccount = "can_link_account"
        case loaded = "loaded"
        case login = "login"
        case changePassword = "change_password"
        case sessionStatus = "session_status"
        case signOut = "sign_out"
        case deleteAccount = "delete_account"
    }

    weak var delegate: FxAContentViewControllerDelegate?

    let profile: Profile

    init(profile: Profile, fxaOptions: FxALaunchParams? = nil) {
        self.profile = profile

        super.init(backgroundColor: UIColor.Photon.Grey20, title: NSAttributedString(string: "Firefox Accounts"))

        self.url = self.createFxAURLWith(fxaOptions, profile: profile)

        NotificationCenter.default.addObserver(self, selector: #selector(userDidVerify), name: .FirefoxAccountVerified, object: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        profile.getAccount()?.updateProfile()

        // If the FxAContentViewController was launched from a FxA deferred link
        // onboarding might not have been shown. Check to see if it needs to be
        // displayed and don't animate.
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.browserViewController.presentIntroViewController(false, animated: false)
        }
    }

    override func makeWebView() -> WKWebView {
        // Handle messages from the content server (via our user script).
        let contentController = WKUserContentController()
        contentController.add(LeakAvoider(delegate: self), name: "accountsCommandHandler")

        // Inject our user script after the page loads.
        if let path = Bundle.main.path(forResource: "FxASignIn", ofType: "js") {
            if let source = try? String(contentsOfFile: path, encoding: .utf8) {
                let userScript = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
                contentController.addUserScript(userScript)
            }
        }

        let config = WKWebViewConfiguration()
        config.userContentController = contentController

        let webView = WKWebView(
            frame: CGRect(width: 1, height: 1),
            configuration: config
        )
        webView.allowsLinkPreview = false
        webView.accessibilityLabel = NSLocalizedString("Web content", comment: "Accessibility label for the main web content view")

        // Don't allow overscrolling.
        webView.scrollView.bounces = false
        return webView
    }

    // Send a message to the content server.
    func injectData(_ type: String, content: [String: Any]) {
        let data = [
            "type": type,
            "content": content,
        ] as [String: Any]
        let json = JSON(data).stringify() ?? ""
        let script = "window.postMessage(\(json), '\(self.url.absoluteString)');"
        settingsWebView.evaluateJavaScript(script, completionHandler: nil)
    }

    fileprivate func onCanLinkAccount(_ data: JSON) {
        //    // We need to confirm a relink - see shouldAllowRelink for more
        //    let ok = shouldAllowRelink(accountData.email);
        let ok = true
        injectData("message", content: ["status": "can_link_account", "data": ["ok": ok]])
    }

    // We're not signed in to a Firefox Account at this time, which we signal by returning an error.
    fileprivate func onSessionStatus(_ data: JSON) {
        injectData("message", content: ["status": "error"])
    }

    // We're not signed in to a Firefox Account at this time. We should never get a sign out message!
    fileprivate func onSignOut(_ data: JSON) {
        injectData("message", content: ["status": "error"])
    }

    // The user has deleted their Firefox Account. Disconnect them!
    fileprivate func onDeleteAccount(_ data: JSON) {
        FxALoginHelper.sharedInstance.applicationDidDisconnect(UIApplication.shared)
        LeanPlumClient.shared.set(attributes: [LPAttributeKey.signedInSync: profile.hasAccount()])
        dismiss(animated: true)
    }

    // The user has signed in to a Firefox Account.  We're done!
    fileprivate func onLogin(_ data: JSON) {
        injectData("message", content: ["status": "login"])

        let app = UIApplication.shared
        let helper = FxALoginHelper.sharedInstance
        helper.delegate = self
        helper.application(app, didReceiveAccountJSON: data)

        if profile.hasAccount() {
            LeanPlumClient.shared.set(attributes: [LPAttributeKey.signedInSync: true])
        }

        LeanPlumClient.shared.track(event: .signsInFxa)
    }

    @objc fileprivate func userDidVerify(_ notification: Notification) {
        guard let account = profile.getAccount() else {
            return
        }
        // We can't verify against the actionNeeded of the account,
        // because of potential race conditions.
        // However, we restrict visibility of this method, and make sure
        // we only Notify via the FxALoginStateMachine.
        let flags = FxALoginFlags(pushEnabled: account.pushRegistration != nil,
                                  verified: true)
        LeanPlumClient.shared.set(attributes: [LPAttributeKey.signedInSync: true])
        DispatchQueue.main.async {
            self.delegate?.contentViewControllerDidSignIn(self, withFlags: flags)
        }
    }

    // The content server page is ready to be shown.
    fileprivate func onLoaded() {
        self.timer?.invalidate()
        self.timer = nil
        self.isLoaded = true
    }

    // Handle a message coming from the content server.
    func handleRemoteCommand(_ rawValue: String, data: JSON) {
        if let command = RemoteCommand(rawValue: rawValue) {
            if !isLoaded && command != .loaded {
                // Work around https://github.com/mozilla/fxa-content-server/issues/2137
                onLoaded()
            }

            switch command {
            case .loaded:
                onLoaded()
            case .login, .changePassword:
                onLogin(data)
            case .canLinkAccount:
                onCanLinkAccount(data)
            case .sessionStatus:
                onSessionStatus(data)
            case .signOut:
                onSignOut(data)
            case .deleteAccount:
                onDeleteAccount(data)
            }
        }
    }

    // Dispatch webkit messages originating from our child webview.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Make sure we're communicating with a trusted page. That is, ensure the origin of the
        // message is the same as the origin of the URL we initially loaded in this web view.
        // Note that this exploit wouldn't be possible if we were using WebChannels; see
        // https://developer.mozilla.org/en-US/docs/Mozilla/JavaScript_code_modules/WebChannel.jsm
        let origin = message.frameInfo.securityOrigin
        guard origin.`protocol` == url.scheme && origin.host == url.host && origin.port == (url.port ?? 0) else {
            print("Ignoring message - \(origin) does not match expected origin: \(url.origin ?? "nil")")
            return
        }

        if message.name == "accountsCommandHandler" {
            let body = JSON(message.body)
            let detail = body["detail"]
            handleRemoteCommand(detail["command"].stringValue, data: detail["data"])
        }
    }

    // Configure the FxA signin url based on any passed options.
    public func createFxAURLWith(_ fxaOptions: FxALaunchParams?, profile: Profile) -> URL {
        let profileUrl = profile.accountConfiguration.signInURL

        guard let launchParams = fxaOptions else {
            return profileUrl
        }

        // Only append certain parameters. Note that you can't override the service and context params.
        var params = launchParams.query
        params.removeValue(forKey: "service")
        params.removeValue(forKey: "context")

        params["action"] = "email"
        // params["style"] = "trailhead" // adds Trailhead banners to the page, making it too long

        let queryURL = params.filter { ["action", "style", "signin", "entrypoint"].contains($0.key) || $0.key.range(of: "utm_") != nil }.map({
            return "\($0.key)=\($0.value)"
        }).joined(separator: "&")


        return  URL(string: "\(profileUrl)&\(queryURL)") ?? profileUrl
    }
}

extension FxAContentViewController: FxAPushLoginDelegate {
    func accountLoginDidSucceed(withFlags flags: FxALoginFlags) {
        DispatchQueue.main.async {
            self.delegate?.contentViewControllerDidSignIn(self, withFlags: flags)
        }
    }

    func accountLoginDidFail() {
        DispatchQueue.main.async {
            self.delegate?.contentViewControllerDidCancel(self)
        }
    }
}

/*
LeakAvoider prevents leaks with WKUserContentController
http://stackoverflow.com/questions/26383031/wkwebview-causes-my-view-controller-to-leak
*/

class LeakAvoider: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        self.delegate?.userContentController(userContentController, didReceive: message)
    }
}
