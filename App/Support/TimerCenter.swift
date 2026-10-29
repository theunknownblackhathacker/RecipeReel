import Foundation
import Observation
import SwiftData
import RecipeCore

/// Countdown timers for steps with a stated time. In memory only.
@MainActor
@Observable
final class TimerCenter {
    private var endDates: [PersistentIdentifier: Date] = [:]

    func start(_ step: Step) {
        guard let minutes = step.minutes, minutes > 0 else { return }
        endDates[step.persistentModelID] = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func cancel(_ step: Step) {
        endDates[step.persistentModelID] = nil
    }

    func endDate(for step: Step) -> Date? {
        endDates[step.persistentModelID]
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
