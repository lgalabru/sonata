import AppKit
import SonataCore
import UserNotifications

/// When tenure notifications are posted.
enum TenureAlerts: String, CaseIterable, Identifiable {
    case every, skipped, off

    var id: Self { self }
    var title: String {
        switch self {
        case .every: "Every tenure"
        case .skipped: "Only when blocks are skipped"
        case .off: "Off"
        }
    }

    static let defaultsKey = "tenureNotifications"
    static var current: TenureAlerts { TenureAlerts(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .every }
}

/// Posts a notification as each of your tenures is summed: blocks produced, and what you kept.
@MainActor
final class TenureNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let model: SonataModel
    private let watch: ValidatorWatch
    private let openPanel: () -> Void
    private var center: UNUserNotificationCenter { .current() }

    init(model: SonataModel, watch: ValidatorWatch, openPanel: @escaping () -> Void) {
        self.model = model
        self.watch = watch
        self.openPanel = openPanel
        super.init()
        center.delegate = self
        watch.onTenureReport = { [weak self] report in self?.post(report) }
        if watch.isPinned, TenureAlerts.current != .off { requestAuthorization() }
    }

    /// Asks once; macOS remembers the answer (System Settings → Notifications → Sonata).
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            debugLog("notifications authorized=\(granted) \(error.map { "\($0)" } ?? "")")
        }
    }

    func post(_ report: TenureReport) {
        let mode = TenureAlerts.current
        guard mode != .off, mode == .every || report.skipped > 0 else { return }
        let split = watch.split
        let name = model.pin(report.identity).displayName
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "tenures"
        if report.skipped > 0 {
            content.title = "\(name) skipped \(report.skipped) of \(report.slots.count) slots"
            content.sound = .default
        } else {
            content.title = "\(name) produced \(report.produced) of \(report.slots.count) blocks"
        }
        if let split {
            content.subtitle = "You made \(sol(split.validatorLamports)) SOL · stakers \(sol(split.stakersLamports)) SOL"
        }
        var body = ["Block rewards \(sol(report.leaderRewardLamports)) SOL", "MEV tips \(sol(report.tipsLamports)) SOL",
                    "\(report.nonVoteTransactions.formatted()) user txs"]
        if report.skipped > 0, report.estimatedMissedLamports > 0 { body.append("~\(sol(report.estimatedMissedLamports)) SOL missed") }
        content.body = body.joined(separator: " · ")
        let request = UNNotificationRequest(identifier: "tenure-\(report.firstSlot)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { debugLog("notification failed: \(error)") }
        }
        debugLog("notification: \(content.title) — \(content.subtitle) — \(content.body)")
    }

    // Show banners even while Sonata's panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { openPanel() }
    }
}
