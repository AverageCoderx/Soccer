import SoccerTrackerCore
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.20, green: 0.55, blue: 1.0)
    static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let card = Color(white: 0.11)
    static let good = Color(red: 0.25, green: 0.82, blue: 0.45)
    static let warn = Color(red: 1.0, green: 0.76, blue: 0.20)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.33)

    static func color(_ level: CheckLevel) -> Color {
        switch level {
        case .good: return good
        case .warn: return warn
        case .bad: return bad
        }
    }

    static func color(_ confidence: MeasurementConfidence?) -> Color {
        switch confidence {
        case .high: return good
        case .medium: return warn
        case .low: return bad
        case nil: return .secondary
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

extension MeasurementConfidence {
    var label: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        }
    }
}
