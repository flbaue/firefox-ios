/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Account
import SwiftKeychainWrapper
import LocalAuthentication

// This file contains all of the settings available in the main settings screen of the app.

private var ShowDebugSettings: Bool = false
private var DebugSettingsClickCount: Int = 0

// For great debugging!
class HiddenSetting: Setting {
    unowned let settings: SettingsTableViewController

    init(settings: SettingsTableViewController) {
        self.settings = settings
        super.init(title: nil)
    }

    override var hidden: Bool {
        return !ShowDebugSettings
    }
}

// Sync setting for connecting a Firefox Account.  Shown when we don't have an account.
class ConnectSetting: WithoutAccountSetting {
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var title: NSAttributedString? {
        return NSAttributedString(string: Strings.FxASignInToSync, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var accessibilityIdentifier: String? { return "SignInToSync" }

    override func onClick(_ navigationController: UINavigationController?) {
        let fxaParams = FxALaunchParams(query: ["entrypoint": "preferences"])
        let viewController = FxAContentViewController(profile: profile, fxaOptions: fxaParams)
        viewController.delegate = self
        viewController.url = settings.profile.accountConfiguration.signInURL
        navigationController?.pushViewController(viewController, animated: true)
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        super.onConfigureCell(cell)
        cell.imageView?.image = UIImage.templateImageNamed("FxA-Default")
        cell.imageView?.tintColor = UIColor.theme.tableView.disabledRowText
        cell.imageView?.layer.cornerRadius = (cell.imageView?.frame.size.width)! / 2
        cell.imageView?.layer.masksToBounds = true
    }
}

class SyncNowSetting: WithAccountSetting {
    let imageView = UIImageView(frame: CGRect(width: 30, height: 30))
    let syncIconWrapper = UIImage.createWithColor(CGSize(width: 30, height: 30), color: UIColor.clear)
    let syncBlueIcon = UIImage(named: "FxA-Sync-Blue")?.createScaled(CGSize(width: 20, height: 20))
    let syncIcon: UIImage? = {
        let image = UIImage(named: "FxA-Sync")?.createScaled(CGSize(width: 20, height: 20))
        return ThemeManager.instance.currentName == .dark ? image?.tinted(withColor: .white) : image
    }()

    // Animation used to rotate the Sync icon 360 degrees while syncing is in progress.
    let continuousRotateAnimation = CABasicAnimation(keyPath: "transform.rotation")

    override init(settings: SettingsTableViewController) {
        super.init(settings: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(stopRotateSyncIcon), name: .ProfileDidFinishSyncing, object: nil)
    }

    fileprivate lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    fileprivate var syncNowTitle: NSAttributedString {
        if !DeviceInfo.hasConnectivity() {
            return NSAttributedString(
                string: Strings.FxANoInternetConnection,
                attributes: [
                    NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.errorText,
                    NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultMediumFont
                ]
            )
        }

        return NSAttributedString(
            string: Strings.FxASyncNow,
            attributes: [
                NSAttributedString.Key.foregroundColor: self.enabled ? UIColor.theme.tableView.syncText : UIColor.theme.tableView.headerTextLight,
                NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultStandardFont
            ]
        )
    }

    fileprivate let syncingTitle = NSAttributedString(string: Strings.SyncingMessageWithEllipsis, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.syncText, NSAttributedString.Key.font: UIFont.systemFont(ofSize: DynamicFontHelper.defaultHelper.DefaultStandardFontSize, weight: UIFont.Weight.regular)])

    func startRotateSyncIcon() {
        DispatchQueue.main.async {
            self.imageView.layer.add(self.continuousRotateAnimation, forKey: "rotateKey")
        }
    }

    @objc func stopRotateSyncIcon() {
        DispatchQueue.main.async {
            self.imageView.layer.removeAllAnimations()
        }
    }

    override var accessoryType: UITableViewCell.AccessoryType { return .none }

    override var image: UIImage? {
        guard let syncStatus = profile.syncManager.syncDisplayState else {
            return syncIcon
        }

        switch syncStatus {
        case .inProgress:
            return syncBlueIcon
        default:
            return syncIcon
        }
    }

    override var title: NSAttributedString? {
        guard let syncStatus = profile.syncManager.syncDisplayState else {
            return syncNowTitle
        }

        switch syncStatus {
        case .bad(let message):
            guard let message = message else { return syncNowTitle }
            return NSAttributedString(string: message, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.errorText, NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultStandardFont])
        case .warning(let message):
            return  NSAttributedString(string: message, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.warningText, NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultStandardFont])
        case .inProgress:
            return syncingTitle
        default:
            return syncNowTitle
        }
    }

    override var status: NSAttributedString? {
        guard let timestamp = profile.syncManager.lastSyncFinishTime else {
            return nil
        }

        let formattedLabel = timestampFormatter.string(from: Date.fromTimestamp(timestamp))
        let attributedString = NSMutableAttributedString(string: formattedLabel)
        let attributes = [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.headerTextLight, NSAttributedString.Key.font: UIFont.systemFont(ofSize: 12, weight: UIFont.Weight.regular)]
        let range = NSRange(location: 0, length: attributedString.length)
        attributedString.setAttributes(attributes, range: range)
        return attributedString
    }

    override var hidden: Bool { return !enabled }

    override var enabled: Bool {
        if !DeviceInfo.hasConnectivity() {
            return false
        }

        return profile.hasSyncableAccount()
    }

    fileprivate lazy var troubleshootButton: UIButton = {
        let troubleshootButton = UIButton(type: .roundedRect)
        troubleshootButton.setTitle(Strings.FirefoxSyncTroubleshootTitle, for: .normal)
        troubleshootButton.addTarget(self, action: #selector(self.troubleshoot), for: .touchUpInside)
        troubleshootButton.tintColor = UIColor.theme.tableView.rowActionAccessory
        troubleshootButton.titleLabel?.font = DynamicFontHelper.defaultHelper.DefaultSmallFont
        troubleshootButton.sizeToFit()
        return troubleshootButton
    }()

    fileprivate lazy var warningIcon: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "AmberCaution"))
        imageView.sizeToFit()
        return imageView
    }()

    fileprivate lazy var errorIcon: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "RedCaution"))
        imageView.sizeToFit()
        return imageView
    }()

    fileprivate let syncSUMOURL = SupportUtils.URLForTopic("sync-status-ios")

    @objc fileprivate func troubleshoot() {
        let viewController = SettingsContentViewController()
        viewController.url = syncSUMOURL
        settings.navigationController?.pushViewController(viewController, animated: true)
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        cell.textLabel?.attributedText = title
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.lineBreakMode = .byWordWrapping
        if let syncStatus = profile.syncManager.syncDisplayState {
            switch syncStatus {
            case .bad(let message):
                if let _ = message {
                    // add the red warning symbol
                    // add a link to the MANA page
                    cell.detailTextLabel?.attributedText = nil
                    cell.accessoryView = troubleshootButton
                    addIcon(errorIcon, toCell: cell)
                } else {
                    cell.detailTextLabel?.attributedText = status
                    cell.accessoryView = nil
                }
            case .warning(_):
                // add the amber warning symbol
                // add a link to the MANA page
                cell.detailTextLabel?.attributedText = nil
                cell.accessoryView = troubleshootButton
                addIcon(warningIcon, toCell: cell)
            case .good:
                cell.detailTextLabel?.attributedText = status
                fallthrough
            default:
                cell.accessoryView = nil
            }
        } else {
            cell.accessoryView = nil
        }
        cell.accessoryType = accessoryType
        cell.isUserInteractionEnabled = !profile.syncManager.isSyncing && DeviceInfo.hasConnectivity()

        // Animation that loops continously until stopped
        continuousRotateAnimation.fromValue = 0.0
        continuousRotateAnimation.toValue = CGFloat(Double.pi)
        continuousRotateAnimation.isRemovedOnCompletion = true
        continuousRotateAnimation.duration = 0.5
        continuousRotateAnimation.repeatCount = .infinity

        // To ensure sync icon is aligned properly with user's avatar, an image is created with proper
        // dimensions and color, then the scaled sync icon is added as a subview.
        imageView.contentMode = .center
        imageView.image = image

        cell.imageView?.subviews.forEach({ $0.removeFromSuperview() })
        cell.imageView?.image = syncIconWrapper
        cell.imageView?.addSubview(imageView)

        if let syncStatus = profile.syncManager.syncDisplayState {
            switch syncStatus {
            case .inProgress:
                self.startRotateSyncIcon()
            default:
                self.stopRotateSyncIcon()
            }
        }
    }

    fileprivate func addIcon(_ image: UIImageView, toCell cell: UITableViewCell) {
        cell.contentView.addSubview(image)

        cell.textLabel?.snp.updateConstraints { make in
            make.leading.equalTo(image.snp.trailing).offset(5)
            make.trailing.lessThanOrEqualTo(cell.contentView)
            make.centerY.equalTo(cell.contentView)
        }

        image.snp.makeConstraints { make in
            make.leading.equalTo(cell.contentView).offset(17)
            make.top.equalTo(cell.textLabel!).offset(2)
        }
    }

    override func onClick(_ navigationController: UINavigationController?) {
        if !DeviceInfo.hasConnectivity() {
            return
        }

        NotificationCenter.default.post(name: .UserInitiatedSyncManually, object: nil)
        profile.syncManager.syncEverything(why: .syncNow)
    }
}

// Sync setting that shows the current Firefox Account status.
class AccountStatusSetting: WithAccountSetting {
    override init(settings: SettingsTableViewController) {
        super.init(settings: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(updateAccount), name: .FirefoxAccountProfileChanged, object: nil)
    }

    @objc func updateAccount(notification: Notification) {
        DispatchQueue.main.async {
            self.settings.tableView.reloadData()
        }
    }

    override var image: UIImage? {
        if let image = profile.getAccount()?.fxaProfile?.avatar.image {
            return image.createScaled(CGSize(width: 30, height: 30))
        }

        let image = UIImage(named: "placeholder-avatar")
        return image?.createScaled(CGSize(width: 30, height: 30))
    }

    override var accessoryType: UITableViewCell.AccessoryType {
        if let account = profile.getAccount() {
            switch account.actionNeeded {
            case .needsVerification:
                // We link to the resend verification email page.
                return .disclosureIndicator
            case .needsPassword:
                 // We link to the re-enter password page.
                return .disclosureIndicator
            case .none:
                // We link to FxA web /settings.
                return .disclosureIndicator
            case .needsUpgrade:
                // In future, we'll want to link to an upgrade page.
                return .none
            }
        }
        return .disclosureIndicator
    }

    override var title: NSAttributedString? {
        if let account = profile.getAccount() {

            if let displayName = account.fxaProfile?.displayName {
                return NSAttributedString(string: displayName, attributes: [NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultStandardFontBold, NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.syncText])
            }

            if let email = account.fxaProfile?.email {
                return NSAttributedString(string: email, attributes: [NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultStandardFontBold, NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.syncText])
            }

            return NSAttributedString(string: account.email, attributes: [NSAttributedString.Key.font: DynamicFontHelper.defaultHelper.DefaultStandardFontBold, NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.syncText])
        }
        return nil
    }

    override var status: NSAttributedString? {
        if let account = profile.getAccount() {
            var string: String

            switch account.actionNeeded {
            case .none:
                return nil
            case .needsVerification:
                string = Strings.FxAAccountVerifyEmail
                break
            case .needsPassword:
                string = Strings.FxAAccountVerifyPassword
                break
            case .needsUpgrade:
                string = Strings.FxAAccountUpgradeFirefox
                break
            }

            let orange = UIColor.theme.tableView.warningText
            let range = NSRange(location: 0, length: string.count)
            let attrs = [NSAttributedString.Key.foregroundColor: orange]
            let res = NSMutableAttributedString(string: string)
            res.setAttributes(attrs, range: range)
            return res
        }
        return nil
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let fxaParams = FxALaunchParams(query: ["entrypoint": "preferences"])
        let viewController = FxAContentViewController(profile: profile, fxaOptions: fxaParams)
        viewController.delegate = self

        if let account = profile.getAccount() {
            switch account.actionNeeded {
            case .none:
                let viewController = SyncContentSettingsViewController()
                viewController.profile = profile
                navigationController?.pushViewController(viewController, animated: true)
                return
            case .needsVerification:
                var cs = URLComponents(url: account.configuration.settingsURL, resolvingAgainstBaseURL: false)
                cs?.queryItems?.append(URLQueryItem(name: "email", value: account.email))
                if let url = cs?.url {
                    viewController.url = url
                }
            case .needsPassword:
                var cs = URLComponents(url: account.configuration.forceAuthURL, resolvingAgainstBaseURL: false)
                cs?.queryItems?.append(URLQueryItem(name: "email", value: account.email))
                if let url = cs?.url {
                    viewController.url = url
                }
            case .needsUpgrade:
                // In future, we'll want to link to an upgrade page.
                return
            }
        }
        navigationController?.pushViewController(viewController, animated: true)
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        super.onConfigureCell(cell)
        if let imageView = cell.imageView {
            imageView.subviews.forEach({ $0.removeFromSuperview() })
            imageView.frame = CGRect(width: 30, height: 30)
            imageView.layer.cornerRadius = (imageView.frame.height) / 2
            imageView.layer.masksToBounds = true
            imageView.image = image
        }
    }
}

// For great debugging!
class RequirePasswordDebugSetting: WithAccountSetting {
    override var hidden: Bool {
        if !ShowDebugSettings {
            return true
        }
        if let account = profile.getAccount(), account.actionNeeded != FxAActionNeeded.needsPassword {
            return false
        }
        return true
    }

    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Debug: require password", comment: "Debug option"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        profile.getAccount()?.makeSeparated()
        settings.tableView.reloadData()
    }
}

// For great debugging!
class RequireUpgradeDebugSetting: WithAccountSetting {
    override var hidden: Bool {
        if !ShowDebugSettings {
            return true
        }
        if let account = profile.getAccount(), account.actionNeeded != FxAActionNeeded.needsUpgrade {
            return false
        }
        return true
    }

    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Debug: require upgrade", comment: "Debug option"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        profile.getAccount()?.makeDoghouse()
        settings.tableView.reloadData()
    }
}

// For great debugging!
class ForgetSyncAuthStateDebugSetting: WithAccountSetting {
    override var hidden: Bool {
        if !ShowDebugSettings {
            return true
        }
        if let _ = profile.getAccount() {
            return false
        }
        return true
    }

    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Debug: forget Sync auth state", comment: "Debug option"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        profile.getAccount()?.syncAuthState.invalidate()
        settings.tableView.reloadData()
    }
}

class DeleteExportedDataSetting: HiddenSetting {
    override var title: NSAttributedString? {
        // Not localized for now.
        return NSAttributedString(string: "Debug: delete exported databases", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let fileManager = FileManager.default
        do {
            let files = try fileManager.contentsOfDirectory(atPath: documentsPath)
            for file in files {
                if file.hasPrefix("browser.") || file.hasPrefix("logins.") {
                    try fileManager.removeItemInDirectory(documentsPath, named: file)
                }
            }
        } catch {
            print("Couldn't delete exported data: \(error).")
        }
    }
}

class ExportBrowserDataSetting: HiddenSetting {
    override var title: NSAttributedString? {
        // Not localized for now.
        return NSAttributedString(string: "Debug: copy databases to app container", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        do {
            let log = Logger.syncLogger
            try self.settings.profile.files.copyMatching(fromRelativeDirectory: "", toAbsoluteDirectory: documentsPath) { file in
                log.debug("Matcher: \(file)")
                return file.hasPrefix("browser.") || file.hasPrefix("logins.") || file.hasPrefix("metadata.")
            }
        } catch {
            print("Couldn't export browser data: \(error).")
        }
    }
}

class ExportLogDataSetting: HiddenSetting {
    override var title: NSAttributedString? {
        // Not localized for now.
        return NSAttributedString(string: "Debug: copy log files to app container", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        Logger.copyPreviousLogsToDocuments()
    }
}

/*
 FeatureSwitchSetting is a boolean switch for features that are enabled via a FeatureSwitch.
 These are usually features behind a partial release and not features released to the entire population.
 */
class FeatureSwitchSetting: BoolSetting {
    let featureSwitch: FeatureSwitch
    let prefs: Prefs

    init(prefs: Prefs, featureSwitch: FeatureSwitch, with title: NSAttributedString) {
        self.featureSwitch = featureSwitch
        self.prefs = prefs
        super.init(prefs: prefs, defaultValue: featureSwitch.isMember(prefs), attributedTitleText: title)
    }

    override var hidden: Bool {
        return !ShowDebugSettings
    }

    override func displayBool(_ control: UISwitch) {
        control.isOn = featureSwitch.isMember(prefs)
    }

    override func writeBool(_ control: UISwitch) {
        self.featureSwitch.setMembership(control.isOn, for: self.prefs)
    }

}

class ForceCrashSetting: HiddenSetting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: "Debug: Force Crash", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        Sentry.shared.crash()
    }
}

class SlowTheDatabase: HiddenSetting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: "Debug: simulate slow database operations", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        debugSimulateSlowDBOperations = !debugSimulateSlowDBOperations
    }
}

class SentryIDSetting: HiddenSetting {
    let deviceAppHash = UserDefaults(suiteName: AppInfo.sharedContainerIdentifier)?.string(forKey: "SentryDeviceAppHash") ?? "0000000000000000000000000000000000000000"
    override var title: NSAttributedString? {
        return NSAttributedString(string: "Debug: \(deviceAppHash)", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText, NSAttributedString.Key.font: UIFont.systemFont(ofSize: 10)])
    }

    override func onClick(_ navigationController: UINavigationController?) {
        copyAppDeviceIDAndPresentAlert(by: navigationController)
    }

    func copyAppDeviceIDAndPresentAlert(by navigationController: UINavigationController?) {
        let alertTitle = Strings.SettingsCopyAppVersionAlertTitle
        let alert = AlertController(title: alertTitle, message: nil, preferredStyle: .alert)
        getSelectedCell(by: navigationController)?.setSelected(false, animated: true)
        UIPasteboard.general.string = deviceAppHash
        navigationController?.topViewController?.present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                alert.dismiss(animated: true)
            }
        }
    }

    func getSelectedCell(by navigationController: UINavigationController?) -> UITableViewCell? {
        let controller = navigationController?.topViewController
        let tableView = (controller as? AppSettingsTableViewController)?.tableView
        guard let indexPath = tableView?.indexPathForSelectedRow else { return nil }
        return tableView?.cellForRow(at: indexPath)
    }
}

// Show the current version of Firefox
class VersionSetting: Setting {
    unowned let settings: SettingsTableViewController

     override var accessibilityIdentifier: String? { return "FxVersion" }

    init(settings: SettingsTableViewController) {
        self.settings = settings
        super.init(title: nil)
    }

    override var title: NSAttributedString? {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        return NSAttributedString(string: String(format: NSLocalizedString("Version %@ (%@)", comment: "Version number of Firefox shown in settings"), appVersion, buildNumber), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        super.onConfigureCell(cell)
    }

    override func onClick(_ navigationController: UINavigationController?) {
        DebugSettingsClickCount += 1
        if DebugSettingsClickCount >= 5 {
            DebugSettingsClickCount = 0
            ShowDebugSettings = !ShowDebugSettings
            settings.tableView.reloadData()
        }
    }

    override func onLongPress(_ navigationController: UINavigationController?) {
        copyAppVersionAndPresentAlert(by: navigationController)
    }

    func copyAppVersionAndPresentAlert(by navigationController: UINavigationController?) {
        let alertTitle = Strings.SettingsCopyAppVersionAlertTitle
        let alert = AlertController(title: alertTitle, message: nil, preferredStyle: .alert)
        getSelectedCell(by: navigationController)?.setSelected(false, animated: true)
        UIPasteboard.general.string = self.title?.string
        navigationController?.topViewController?.present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                alert.dismiss(animated: true)
            }
        }
    }
    
    func getSelectedCell(by navigationController: UINavigationController?) -> UITableViewCell? {
        let controller = navigationController?.topViewController
        let tableView = (controller as? AppSettingsTableViewController)?.tableView
        guard let indexPath = tableView?.indexPathForSelectedRow else { return nil }
        return tableView?.cellForRow(at: indexPath)
    }
}

// Opens the license page in a new tab
class LicenseAndAcknowledgementsSetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Licenses", comment: "Settings item that opens a tab containing the licenses. See http://mzl.la/1NSAWCG"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var url: URL? {
        return URL(string: "\(InternalURL.baseUrl)/\(AboutLicenseHandler.path)")
    }

    override func onClick(_ navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

// Opens about:rights page in the content view controller
class YourRightsSetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Your Rights", comment: "Your Rights settings section title"), attributes:
            [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var url: URL? {
        return URL(string: "https://www.mozilla.org/about/legal/terms/firefox/")
    }

    override func onClick(_ navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

// Opens the on-boarding screen again
class ShowIntroductionSetting: Setting {
    let profile: Profile

    override var accessibilityIdentifier: String? { return "ShowTour" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: NSLocalizedString("Show Tour", comment: "Show the on-boarding screen again from the settings"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.dismiss(animated: true, completion: {
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
                appDelegate.browserViewController.presentIntroViewController(true)
            }
        })
    }
}

class SendFeedbackSetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Send Feedback", comment: "Menu item in settings used to open input.mozilla.org where people can submit feedback"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var url: URL? {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        return URL(string: "https://input.mozilla.org/feedback/fxios/\(appVersion)")
    }

    override func onClick(_ navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

class SendAnonymousUsageDataSetting: BoolSetting {
    init(prefs: Prefs, delegate: SettingsDelegate?) {
        let statusText = NSMutableAttributedString()
        statusText.append(NSAttributedString(string: Strings.SendUsageSettingMessage, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.headerTextLight]))
        statusText.append(NSAttributedString(string: " "))
        statusText.append(NSAttributedString(string: Strings.SendUsageSettingLink, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.general.highlightBlue]))

        super.init(
            prefs: prefs, prefKey: AppConstants.PrefSendUsageData, defaultValue: true,
            attributedTitleText: NSAttributedString(string: Strings.SendUsageSettingTitle),
            attributedStatusText: statusText,
            settingDidChange: {
                AdjustIntegration.setEnabled($0)
                LeanPlumClient.shared.set(attributes: [LPAttributeKey.telemetryOptIn: $0])
                LeanPlumClient.shared.set(enabled: $0)
            }
        )
    }

    override var url: URL? {
        return SupportUtils.URLForTopic("adjust")
    }

    override func onClick(_ navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

// Opens the SUMO page in a new tab
class OpenSupportPageSetting: Setting {
    init(delegate: SettingsDelegate?) {
        super.init(title: NSAttributedString(string: NSLocalizedString("Help", comment: "Show the SUMO support page from the Support section in the settings. see http://mzl.la/1dmM8tZ"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]),
            delegate: delegate)
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.dismiss(animated: true) {
            if let url = URL(string: "https://support.mozilla.org/products/ios") {
                self.delegate?.settingsOpenURLInNewTab(url)
            }
        }
    }
}

// Opens the search settings pane
class SearchSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var style: UITableViewCell.CellStyle { return .value1 }

    override var status: NSAttributedString { return NSAttributedString(string: profile.searchEngines.defaultEngine.shortName) }

    override var accessibilityIdentifier: String? { return "Search" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: NSLocalizedString("Search", comment: "Open search section of settings"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = SearchSettingsTableViewController()
        viewController.model = profile.searchEngines
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class LoginsSetting: Setting {
    let profile: Profile
    var tabManager: TabManager!
    weak var navigationController: UINavigationController?
    weak var settings: AppSettingsTableViewController?

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "Logins" }

    init(settings: SettingsTableViewController, delegate: SettingsDelegate?) {
        self.profile = settings.profile
        self.tabManager = settings.tabManager
        self.navigationController = settings.navigationController
        self.settings = settings as? AppSettingsTableViewController
        
        super.init(title: NSAttributedString(string: Strings.LoginsAndPasswordsTitle, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]),
                   delegate: delegate)
    }

    func deselectRow () {
        if let selectedRow = self.settings?.tableView.indexPathForSelectedRow {
            self.settings?.tableView.deselectRow(at: selectedRow, animated: true)
        }
    }

    override func onClick(_: UINavigationController?) {
        deselectRow()
        
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate, let navController = navigationController else { return }
        LoginListViewController.create(authenticateInNavigationController: navController, profile: profile, settingsDelegate: appDelegate.browserViewController).uponQueue(.main) { loginsVC in
            guard let loginsVC = loginsVC else { return }
            LeanPlumClient.shared.track(event: .openedLogins)
            navController.pushViewController(loginsVC, animated: true)
        }
    }
}

class TouchIDPasscodeSetting: Setting {
    let profile: Profile
    var tabManager: TabManager!

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "TouchIDPasscode" }

    init(settings: SettingsTableViewController, delegate: SettingsDelegate? = nil) {
        self.profile = settings.profile
        self.tabManager = settings.tabManager
        let localAuthContext = LAContext()

        let title: String
        if localAuthContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            if localAuthContext.biometryType == .faceID {
                title = AuthenticationStrings.faceIDPasscodeSetting
            } else {
                title = AuthenticationStrings.touchIDPasscodeSetting
            }
        } else {
            title = AuthenticationStrings.passcode
        }
        super.init(title: NSAttributedString(string: title, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]),
                   delegate: delegate)
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = AuthenticationSettingsViewController()
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class ContentBlockerSetting: Setting {
    let profile: Profile
    var tabManager: TabManager!
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }
    override var accessibilityIdentifier: String? { return "TrackingProtection" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        self.tabManager = settings.tabManager
        super.init(title: NSAttributedString(string: Strings.SettingsTrackingProtectionSectionName, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = ContentBlockerSettingViewController(prefs: profile.prefs)
        viewController.profile = profile
        viewController.tabManager = tabManager
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class ClearPrivateDataSetting: Setting {
    let profile: Profile
    var tabManager: TabManager!

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "ClearPrivateData" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        self.tabManager = settings.tabManager

        let clearTitle = Strings.SettingsDataManagementSectionName
        super.init(title: NSAttributedString(string: clearTitle, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = ClearPrivateDataTableViewController()
        viewController.profile = profile
        viewController.tabManager = tabManager
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class PrivacyPolicySetting: Setting {
    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Privacy Policy", comment: "Show Firefox Browser Privacy Policy page from the Privacy section in the settings. See https://www.mozilla.org/privacy/firefox/"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var url: URL? {
        return URL(string: "https://www.mozilla.org/privacy/firefox/")
    }

    override func onClick(_ navigationController: UINavigationController?) {
        setUpAndPushSettingsContentViewController(navigationController)
    }
}

class ChinaSyncServiceSetting: WithoutAccountSetting {
    override var accessoryType: UITableViewCell.AccessoryType { return .none }
    var prefs: Prefs { return settings.profile.prefs }
    let prefKey = "useChinaSyncService"

    override var title: NSAttributedString? {
        return NSAttributedString(string: "本地同步服务", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var status: NSAttributedString? {
        return NSAttributedString(string: "禁用后使用全球服务同步数据", attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.headerTextLight])
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        super.onConfigureCell(cell)
        let control = UISwitchThemed()
        control.onTintColor = UIColor.theme.tableView.controlTint
        control.addTarget(self, action: #selector(switchValueChanged), for: .valueChanged)
        control.isOn = prefs.boolForKey(prefKey) ?? BrowserProfile.isChinaEdition
        cell.accessoryView = control
        cell.selectionStyle = .none
    }

    @objc func switchValueChanged(_ toggle: UISwitch) {
        prefs.setObject(toggle.isOn, forKey: prefKey)
    }
}

class StageSyncServiceDebugSetting: WithoutAccountSetting {
    override var accessoryType: UITableViewCell.AccessoryType { return .none }
    var prefs: Prefs { return settings.profile.prefs }

    var prefKey: String = "useStageSyncService"

    override var accessibilityIdentifier: String? { return "DebugStageSync" }

    override var hidden: Bool {
        if !ShowDebugSettings {
            return true
        }
        if let _ = profile.getAccount() {
            return true
        }
        return false
    }

    override var title: NSAttributedString? {
        return NSAttributedString(string: NSLocalizedString("Debug: use stage servers", comment: "Debug option"), attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override var status: NSAttributedString? {
        let configurationURL = profile.accountConfiguration.authEndpointURL
        return NSAttributedString(string: configurationURL.absoluteString, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.headerTextLight])
    }

    override func onConfigureCell(_ cell: UITableViewCell) {
        super.onConfigureCell(cell)
        let control = UISwitchThemed()
        control.onTintColor = UIColor.theme.tableView.controlTint
        control.addTarget(self, action: #selector(switchValueChanged), for: .valueChanged)
        control.isOn = prefs.boolForKey(prefKey) ?? false
        cell.accessoryView = control
        cell.selectionStyle = .none
    }

    @objc func switchValueChanged(_ toggle: UISwitch) {
        prefs.setObject(toggle.isOn, forKey: prefKey)
        settings.tableView.reloadData()
    }
}

class NewTabPageSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "NewTab" }

    override var status: NSAttributedString {
        return NSAttributedString(string: NewTabAccessors.getNewTabPage(self.profile.prefs).settingTitle)
    }

    override var style: UITableViewCell.CellStyle { return .value1 }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: Strings.SettingsNewTabSectionName, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = NewTabContentSettingsViewController(prefs: profile.prefs)
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class HomeSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "Home" }

    override var status: NSAttributedString {
        return NSAttributedString(string: NewTabAccessors.getHomePage(self.profile.prefs).settingTitle)
    }

    override var style: UITableViewCell.CellStyle { return .value1 }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile

        super.init(title: NSAttributedString(string: Strings.AppMenuOpenHomePageTitleString, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = HomePageSettingViewController(prefs: profile.prefs)
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }
}

@available(iOS 12.0, *)
class SiriPageSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "SiriSettings" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile

        super.init(title: NSAttributedString(string: Strings.SettingsSiriSectionName, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = SiriSettingsViewController(prefs: profile.prefs)
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class OpenWithSetting: Setting {
    let profile: Profile

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "OpenWith.Setting" }

    override var status: NSAttributedString {
        guard let provider = self.profile.prefs.stringForKey(PrefsKeys.KeyMailToOption), provider != "mailto:" else {
            return NSAttributedString(string: "")
        }
        if let path = Bundle.main.path(forResource: "MailSchemes", ofType: "plist"), let dictRoot = NSArray(contentsOfFile: path) {
            let mailProvider = dictRoot.compactMap({$0 as? NSDictionary }).first { (dict) -> Bool in
                return (dict["scheme"] as? String) == provider
            }
            return NSAttributedString(string: (mailProvider?["name"] as? String) ?? "")
        }
        return NSAttributedString(string: "")
    }

    override var style: UITableViewCell.CellStyle { return .value1 }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile

        super.init(title: NSAttributedString(string: Strings.SettingsOpenWithSectionName, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = OpenWithSettingsViewController(prefs: profile.prefs)
        navigationController?.pushViewController(viewController, animated: true)
    }
}

class AdvancedAccountSetting: HiddenSetting {
    let profile: Profile

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "AdvancedAccount.Setting" }

    override var title: NSAttributedString? {
        return NSAttributedString(string: Strings.SettingsAdvancedAccountTitle, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText])
    }

    override init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(settings: settings)
    }

    override func onClick(_ navigationController: UINavigationController?) {
        let viewController = AdvancedAccountSettingViewController()
        viewController.profile = profile
        navigationController?.pushViewController(viewController, animated: true)
    }

    override var hidden: Bool {
        return !ShowDebugSettings || profile.hasAccount()
    }
}

class ThemeSetting: Setting {
    let profile: Profile
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }
    override var style: UITableViewCell.CellStyle { return .value1 }
    override var accessibilityIdentifier: String? { return "DisplayThemeOption" }

    override var status: NSAttributedString {
        if ThemeManager.instance.automaticBrightnessIsOn {
            return NSAttributedString(string: Strings.DisplayThemeAutomaticStatusLabel)
        }
        return NSAttributedString(string: "")
    }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: Strings.SettingsDisplayThemeTitle, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(ThemeSettingsController(), animated: true)
    }
}

class TranslationSetting: Setting {
    let profile: Profile
    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }
    override var style: UITableViewCell.CellStyle { return .value1 }
    override var accessibilityIdentifier: String? { return "TranslationOption" }

    init(settings: SettingsTableViewController) {
        self.profile = settings.profile
        super.init(title: NSAttributedString(string: Strings.SettingTranslateSnackBarTitle, attributes: [NSAttributedString.Key.foregroundColor: UIColor.theme.tableView.rowText]))
    }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(TranslationSettingsController(profile), animated: true)
    }
}
