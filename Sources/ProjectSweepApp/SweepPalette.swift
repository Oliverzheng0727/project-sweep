import AppKit
import CleanupCore
import SwiftUI

enum SweepPalette {
    static var accent: Color { .accentColor }
    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var border: Color { Color(nsColor: .separatorColor) }

    static func file(_ category: CleanupCategory) -> Color {
        switch category {
        case .source: .indigo
        case .cache, .toolCache: .green
        case .session, .projectMemory: .purple
        case .build, .dependency, .temporary: .orange
        case .document, .project: .blue
        case .other, .toolLog: .secondary
        }
    }

    static func risk(_ risk: CleanupRisk) -> Color {
        switch risk {
        case .recommended: .green
        case .review, .unavailable: .orange
        case .protected: .purple
        }
    }

    static func riskIcon(_ risk: CleanupRisk) -> String {
        switch risk {
        case .recommended: "sparkles"
        case .review: "magnifyingglass"
        case .protected: "lock.shield"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    @MainActor static func sidebar(_ page: SweepState.Page) -> Color {
        switch page {
        case .project: .blue
        case .tools: .purple
        case .skills: .indigo
        case .records: .green
        case .settings: .secondary
        }
    }
}
