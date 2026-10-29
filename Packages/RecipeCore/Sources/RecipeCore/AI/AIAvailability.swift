import Foundation
import FoundationModels

/// Whether the on-device Apple Intelligence model can be used right now.
public enum AIAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case other(String)

    public static func current() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable(let reason):
            return .other(String(describing: reason))
        }
    }

    public var isAvailable: Bool { self == .available }

    /// Message for the user.
    public var message: String {
        switch self {
        case .available:
            "Apple Intelligence is ready."
        case .deviceNotEligible:
            "This iPhone can't run Apple Intelligence, so RecipeReel can't extract recipes on it. Transcripts and on-screen text still work."
        case .notEnabled:
            "Apple Intelligence is turned off. Turn it on in Settings → Apple Intelligence & Siri, then try again."
        case .modelNotReady:
            "Apple Intelligence is still downloading or busy. Try again in a few minutes."
        case .other(let reason):
            "Apple Intelligence isn't available right now (\(reason))."
        }
    }

    /// Short status for Diagnostics and logs.
    public var shortLabel: String {
        switch self {
        case .available: "available"
        case .deviceNotEligible: "device not eligible"
        case .notEnabled: "turned off"
        case .modelNotReady: "model not ready"
        case .other(let reason): "unavailable (\(reason))"
        }
    }
}
