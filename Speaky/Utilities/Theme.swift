import SwiftUI
import AppKit

// MARK: - Hand Cursor Button Style

struct HandCursorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HandCursorBody(configuration: configuration)
    }
}

/// Tracks hover state to safely pop cursor on disappear.
private struct HandCursorBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

extension ButtonStyle where Self == HandCursorButtonStyle {
    static var handCursor: HandCursorButtonStyle { HandCursorButtonStyle() }
}

enum Theme {
    // Primary brand colors from app icon
    static let amber = Color(red: 0.961, green: 0.651, blue: 0.133)      // #F5A622 - main gold/amber
    static let amberLight = Color(red: 0.976, green: 0.733, blue: 0.298)  // #F9BB4C - lighter variant
    static let amberDark = Color(red: 0.839, green: 0.545, blue: 0.059)   // #D68B0F - darker variant

    // Background colors
    static let bgDark = Color(red: 0.09, green: 0.09, blue: 0.10)         // #171718 - deep dark bg
    static let bgCard = Color(red: 0.13, green: 0.13, blue: 0.14)         // #212123 - card bg
    static let bgElevated = Color(red: 0.17, green: 0.17, blue: 0.18)     // #2B2B2E - elevated surface

    // Text colors
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let textTertiary = Color.white.opacity(0.4)

    // Status colors
    static let success = Color(red: 0.30, green: 0.78, blue: 0.40)        // Green
    static let recording = Color(red: 0.95, green: 0.30, blue: 0.30)      // Red
    static let info = Color(red: 0.35, green: 0.60, blue: 0.95)           // Blue

    // Corner radii
    static let cornerRadiusSmall: CGFloat = 8
    static let cornerRadiusMedium: CGFloat = 12
    static let cornerRadiusLarge: CGFloat = 16

    // Gradients
    static let amberGradient = LinearGradient(
        colors: [amber, amberDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let bgGradient = LinearGradient(
        colors: [bgDark, Color(red: 0.07, green: 0.07, blue: 0.08)],
        startPoint: .top,
        endPoint: .bottom
    )
}
