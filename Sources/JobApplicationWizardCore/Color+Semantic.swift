import SwiftUI

extension Color {
    static var controlBackground: Color {
        #if os(macOS)
        Color(.controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    static var textBackground: Color {
        #if os(macOS)
        Color(.textBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }

    static var windowBackground: Color {
        #if os(macOS)
        Color(.windowBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }
}
