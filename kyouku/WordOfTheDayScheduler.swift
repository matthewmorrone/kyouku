import Foundation
import UserNotifications

enum WordOfTheDayScheduler {
    static let enabledKey = "wordOfTheDay.enabled"
    static let hourKey = "wordOfTheDay.hour"
    static let minuteKey = "wordOfTheDay.minute"

    static let requestPrefix = "wotd_"

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static func pendingWordOfTheDayRequestCount() async -> Int {
        let ids = await pendingWordOfTheDayIdentifiers()
        return ids.count
    }

    static func clearPendingWordOfTheDayRequests() async {
        let ids = await pendingWordOfTheDayIdentifiers()
        guard ids.isEmpty == false else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func refreshScheduleIfEnabled(words: [Word], hour: Int, minute: Int, enabled: Bool, daysToSchedule: Int = 14) async {
        guard enabled else {
            await clearPendingWordOfTheDayRequests()
            return
        }

        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else {
            // Don't schedule if we can't.
            await clearPendingWordOfTheDayRequests()
            return
        }

        await scheduleUpcoming(words: words, hour: hour, minute: minute, daysToSchedule: daysToSchedule)
    }

    static func sendTestNotification(word: Word?) async {
        guard let word else { return }
        let content = makeContent(for: word)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: requestPrefix + "test_\(UUID().uuidString)", content: content, trigger: trigger)
        _ = await addRequest(request)
    }

    // MARK: - Internals

    private static func scheduleUpcoming(words: [Word], hour: Int, minute: Int, daysToSchedule: Int) async {
        await clearPendingWordOfTheDayRequests()
        guard words.isEmpty == false else { return }

        // Randomize selection across the full saved word list.
        // We shuffle once per scheduling run to keep the upcoming batch varied while
        // still avoiding accidental bias toward earlier items.
        let shuffled = words.shuffled()

        let calendar = Calendar.current
        let now = Date()

        // Keep within iOS pending notification limit (64). We only schedule word-of-the-day requests.
        let count = max(1, min(daysToSchedule, 30))

        for dayOffset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = max(0, min(23, hour))
            comps.minute = max(0, min(59, minute))

            let word = pickWord(forDayOffset: dayOffset, from: shuffled)
            let content = makeContent(for: word)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = requestPrefix + identifierDateString(from: comps)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            _ = await addRequest(request)
        }
    }

    private static func pickWord(forDayOffset dayOffset: Int, from words: [Word]) -> Word {
        guard words.isEmpty == false else {
            return Word(surface: "", kana: nil, meaning: "")
        }
        // Randomized upstream; rotate through shuffled order to reduce duplicates
        // within the scheduled batch.
        let idx = abs(dayOffset) % words.count
        return words[idx]
    }

    private static func makeContent(for word: Word) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Word of the Day"

        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaning = word.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = word.kana?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let kana, kana.isEmpty == false, kana != surface {
            content.body = "\(surface)【\(kana)】 \(meaning)"
        } else {
            content.body = "\(surface) \(meaning)"
        }
        content.sound = .default

        content.userInfo["surface"] = word.surface
        if let kana { content.userInfo["kana"] = kana }
        content.userInfo["meaning"] = word.meaning
        content.userInfo["wordID"] = word.id.uuidString

        return content
    }

    private static func pendingWordOfTheDayIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                let ids = requests.map { $0.identifier }.filter { $0.hasPrefix(requestPrefix) }
                continuation.resume(returning: ids)
            }
        }
    }

    private static func identifierDateString(from components: DateComponents) -> String {
        let y = components.year ?? 0
        let m = components.month ?? 0
        let d = components.day ?? 0
        return String(format: "%04d%02d%02d", y, m, d)
    }

    private static func addRequest(_ request: UNNotificationRequest) async -> Error? {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error)
            }
        }
    }
}
