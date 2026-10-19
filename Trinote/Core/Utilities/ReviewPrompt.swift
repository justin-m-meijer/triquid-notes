import StoreKit
import UIKit

/// Asks for an App Store rating through StoreKit's own prompt, and only once someone clearly uses the app.
///
/// The prompt comes when a note closes after an edit, never while typing: by then the person has just done
/// what the app is for. It waits for saves on `minimumSaveDays` different days and `minimumDaysSinceFirstSave`
/// days since the first one, and asks at most once per app version. StoreKit itself shows it no more than
/// three times a year and not at all when the person switched rating prompts off, so this only decides
/// when asking makes sense, not whether a prompt appears.
@MainActor
enum ReviewPrompt {
    static let minimumSaveDays = 4
    static let minimumDaysSinceFirstSave = 7

    /// The App Store's "write a review" page, for the Settings row that is always there.
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id6816314389?action=write-review")!

    private static let saveDaysKey = "reviewPrompt.saveDays"
    private static let firstSaveKey = "reviewPrompt.firstSave"
    private static let promptedVersionKey = "reviewPrompt.promptedVersion"
    private static var savedSinceLastCheck = false

    /// Call after a note body was written. Cheap: one day stamp per calendar day.
    static func recordSave(now: Date = .now, defaults: UserDefaults = .standard) {
        savedSinceLastCheck = true
        if defaults.object(forKey: firstSaveKey) == nil { defaults.set(now, forKey: firstSaveKey) }
        let day = dayStamp(now)
        var days = defaults.stringArray(forKey: saveDaysKey) ?? []
        guard !days.contains(day) else { return }
        days.append(day)
        // Only the count matters; a few more than needed is plenty.
        defaults.set(Array(days.suffix(minimumSaveDays + 2)), forKey: saveDaysKey)
    }

    /// Call when a note closes. Asks only if something was saved since the last check and the usage bar is met.
    static func noteClosed(now: Date = .now, defaults: UserDefaults = .standard) {
        guard savedSinceLastCheck else { return }
        savedSinceLastCheck = false
        guard shouldAsk(now: now, defaults: defaults, version: currentVersion) else { return }
        defaults.set(currentVersion, forKey: promptedVersionKey)
        // After the navigation settles, so the prompt does not land on a view that is still sliding away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
            AppStore.requestReview(in: scene)
        }
    }

    static func shouldAsk(now: Date, defaults: UserDefaults, version: String) -> Bool {
        guard defaults.string(forKey: promptedVersionKey) != version else { return false }
        guard (defaults.stringArray(forKey: saveDaysKey) ?? []).count >= minimumSaveDays else { return false }
        guard let first = defaults.object(forKey: firstSaveKey) as? Date else { return false }
        return now.timeIntervalSince(first) >= Double(minimumDaysSinceFirstSave) * 86_400
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static func dayStamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
