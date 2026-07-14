import Foundation
import UserNotifications
import ReclaimKit

/// Posts at most one notification per condition per day, and only when enabled.
enum NotificationManager {
    static func checkAfterScan(model: AppModel) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "notifyEnabled") else { return }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        guard granted else { return }

        if let values = try? URL(filePath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let thresholdGB = defaults.integer(forKey: "notifyFreeSpaceGB")
            if free < Int64(thresholdGB) * 1_000_000_000 {
                await post(center, id: "low-free-space",
                           title: "Disk space is low",
                           body: "\(Int64(free).formattedBytes) free. Reclaim found \(model.safeBytes.formattedBytes) safe to clean.")
            }
        }

        let devThresholdGB = defaults.integer(forKey: "notifyDevStorageGB")
        if model.totalBytes > Int64(devThresholdGB) * 1_000_000_000 {
            await post(center, id: "dev-storage",
                       title: "Development storage is growing",
                       body: "\(model.totalBytes.formattedBytes) of development storage found, \(model.safeBytes.formattedBytes) safe to clean.")
        }
    }

    private static func post(_ center: UNUserNotificationCenter, id: String, title: String, body: String) async {
        let key = "lastNotified-\(id)"
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           Date.now.timeIntervalSince(last) < 86_400 {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        UserDefaults.standard.set(Date.now, forKey: key)
    }
}
