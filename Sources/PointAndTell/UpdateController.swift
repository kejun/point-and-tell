#if os(macOS)
import AppKit
import Sparkle
import PointAndTellCore

/// Uses Sparkle's standard download/install UI. All callbacks are on the main
/// thread; automatic offers wait locally without starting another network poll.
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    private let session = UpdateSessionGate()
    private let activity: () -> UpdateActivity
    private let save: () -> Bool
    private let mayPresentAutomatically: () -> Bool
    private let changed: () -> Void
    private var pendingOffer = false
    private var offerTimer: Timer?
    private weak var checkItem: NSMenuItem?
    private var unavailableReason: String?
    var blocksWork: Bool { session.blocksWork }

    init(activity: @escaping () -> UpdateActivity, save: @escaping () -> Bool,
         mayPresentAutomatically: @escaping () -> Bool, changed: @escaping () -> Void) {
        self.activity = activity; self.save = save
        self.mayPresentAutomatically = mayPresentAutomatically; self.changed = changed
        super.init()
    }

    func addMenuItems(to menu: NSMenu) {
        let check = menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self; checkItem = check
        let automatic = menu.addItem(withTitle: "自动检查更新", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
    }

    func start() {
        guard controller == nil else { return }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            unavailableReason = "此开发构建未配置更新签名，请安装正式发布的版本。"
            checkItem?.toolTip = unavailableReason
            return
        }
        let candidate = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        do {
            try candidate.updater.start()
            controller = candidate
        } catch {
            unavailableReason = "更新服务暂不可用：" + error.localizedDescription
            checkItem?.toolTip = unavailableReason
        }
    }

    @objc private func checkForUpdates() {
        guard let controller = controller, controller.updater.canCheckForUpdates else { return }
        if !session.blocksWork {
            guard session.begin(activity: activity(), save: save) else { return }
            changed()
        }
        pendingOffer = false; stopOfferTimer()
        controller.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticChecks() {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates.toggle()
        // A previously offered update remains reachable through Check for Updates.
        // Turning checks off must not result in an automatic popup later.
        if !updater.automaticallyChecksForUpdates { stopOfferTimer() }
        else if pendingOffer { scheduleOffer() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let updater = controller?.updater else { return false }
        if menuItem.action == #selector(toggleAutomaticChecks) {
            menuItem.state = updater.automaticallyChecksForUpdates ? .on : .off
            return !session.blocksWork
        }
        return activity().canPresentUpdate && updater.canCheckForUpdates
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard activity().canPresentUpdate else {
            throw NSError(domain: "PointAndTell.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先完成录制、转写或导出，再检查更新。"])
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Always take over scheduling. A check may finish after recording begins.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        pendingOffer = true
        checkItem?.title = "更新到 v" + update.displayVersionString + "…"
        scheduleOffer()
    }

    private func scheduleOffer() {
        guard offerTimer == nil else { return }
        offerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.pendingOffer,
                  self.controller?.updater.automaticallyChecksForUpdates == true,
                  NSApp.isActive, self.mayPresentAutomatically(),
                  self.activity().canPresentUpdate else { return }
            // Save errors should require an explicit retry, not a two-second alert loop.
            self.stopOfferTimer()
            self.checkForUpdates()
        }
    }

    private func stopOfferTimer() { offerTimer?.invalidate(); offerTimer = nil }

    func standardUserDriverWillFinishUpdateSession() { finishSession() }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { finishSession() }

    /// Sparkle respects NSApplication's termination veto. If a late disk error
    /// prevents saving, restore editing so the user can repair/save and retry.
    func terminationWasCancelled() {
        session.finish(); changed()
    }

    private func finishSession() {
        pendingOffer = false; stopOfferTimer()
        checkItem?.title = "检查更新…"
        session.finish(); changed()
    }

    deinit { offerTimer?.invalidate() }
}
#endif
