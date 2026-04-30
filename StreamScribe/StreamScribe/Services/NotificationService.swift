import Foundation
import Combine
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for keyword-hit alerts.
///
/// Why a service object instead of calling UNUserNotificationCenter directly from the
/// engine: we need to expose authorization status to the UI so the user can see when
/// macOS has silently denied notifications (which is common for unsigned dev builds
/// and apps that haven't been added to System Settings → Notifications). Without that
/// surface, "I enabled the toggle but nothing happens" becomes unattributable.
///
/// We deliberately keep this lightweight — no rich notifications, no actions, no
/// categories. Just a title + a snippet of matched text + a tag so we can later
/// dedupe or clear them as a group if needed.
///
/// IMPLEMENTATION NOTE — concurrency: the class is NOT marked `@MainActor` at the type
/// level. Doing so breaks `ObservableObject` synthesis (Swift can't synthesize the
/// `objectWillChange` publisher for an actor-isolated class) and also blocks
/// `@Published` from referencing its Combine-defined `init(wrappedValue:)`. We follow
/// the same pattern as `TranscriptionEngine`: per-method `@MainActor` on the bits that
/// mutate published state. The non-isolated reads (`authorizationDescription`,
/// `isAuthorized`) are safe because reading a `@Published` value is legal from any
/// context — only writes need synchronization.
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    /// Mirrors `UNAuthorizationStatus` but published for SwiftUI bindings. We default
    /// to `.notDetermined` and update after each `requestAuthorization` call and on
    /// app launch.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Human-readable description of the current authorization state, suitable for
    /// inline display in the sidebar.
    var authorizationDescription: String {
        switch authorizationStatus {
        case .notDetermined:    return "Not requested yet"
        case .denied:           return "Denied — enable in System Settings → Notifications"
        case .authorized:       return "Allowed"
        case .provisional:      return "Allowed (provisional)"
        case .ephemeral:        return "Allowed (ephemeral)"
        @unknown default:       return "Unknown"
        }
    }

    /// True when the system will actually deliver notifications. Used to gate the
    /// notify-on-hit toggle's effective behavior.
    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private init() {
        // Refresh status at startup so the UI reflects the OS state without requiring
        // a request. If the user previously granted/denied, we'll see it here. The
        // refresh hops to MainActor on its own, so kicking it off from this nonisolated
        // init is safe.
        Task { @MainActor [weak self] in
            await self?.refreshAuthorizationStatus()
        }
    }

    /// Re-read the current status from the system. Call this when the user toggles
    /// the notify-on-hit setting back on, or on app foregrounding, in case the user
    /// changed permissions in System Settings while the app was running.
    @MainActor
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
    }

    /// Prompt the user for permission. Returns the resulting status (also published).
    /// On unsigned dev builds macOS may silently deny without showing the prompt —
    /// in that case the status will remain `.denied` and the UI surfaces that string.
    @discardableResult
    @MainActor
    func requestAuthorization() async -> UNAuthorizationStatus {
        do {
            // We only need alerts + sounds. We don't post badges since this isn't a
            // dock-icon kind of app.
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            // The `granted` boolean is informative but the authoritative source is
            // the settings object — re-read after the request.
            await refreshAuthorizationStatus()
            _ = granted
        } catch {
            print("[NotificationService] Authorization request failed: \(error)")
            await refreshAuthorizationStatus()
        }
        return authorizationStatus
    }

    /// Post a local notification for a keyword hit. Silently no-ops if the user
    /// hasn't authorized notifications — we don't want to log noise on every hit
    /// when notifications are off (which is the engine's default state).
    @MainActor
    func postKeywordHit(keyword: String, snippet: String, speaker: String?) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "Keyword: \(keyword)"
        // Include the speaker label (display-side) when present so the user can
        // glance at the notification and know who said it. We accept the resolved
        // display name here, not the machine label, because the engine has the
        // name map and can pre-resolve before calling us.
        if let speaker, !speaker.isEmpty {
            content.subtitle = speaker
        }
        // Trim very long snippets — notifications get truncated by the system anyway,
        // and a tight snippet keeps the toast readable.
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = trimmed.count > 240
            ? String(trimmed.prefix(237)) + "…"
            : trimmed
        content.sound = .default
        // Tag with a stable thread identifier so macOS can group these in the
        // Notification Center under one stack rather than spamming individual rows.
        content.threadIdentifier = "streamscribe.keyword.hits"

        // Immediate delivery: nil trigger = "show now". Identifiers must be unique
        // per pending notification or the system replaces in-flight ones; UUID is
        // simplest and we don't need to look these up later.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NotificationService] add() failed: \(error)")
            }
        }
    }
}
