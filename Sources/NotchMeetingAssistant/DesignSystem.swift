import SwiftUI

/// One restrained palette for the command surfaces, reading views and provider configuration.
enum CompanionPalette {
    static let canvas = Color(red: 23 / 255, green: 23 / 255, blue: 24 / 255)
    static let sidebar = canvas
    static let surface = Color(red: 32 / 255, green: 32 / 255, blue: 34 / 255)
    static let raised = Color(red: 43 / 255, green: 43 / 255, blue: 46 / 255)
    static let wash = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.085)
}

struct CompanionPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .tint(.black)
            .padding(.horizontal, 17).padding(.vertical, 11)
            .background(Color.white.opacity(enabled ? (configuration.isPressed ? 0.8 : 0.96) : 0.25), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(enabled ? 0.28 : 0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(enabled ? 0.2 : 0), radius: 4, y: 2)
            .contentShape(Capsule())
    }
}

struct CompanionSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(enabled ? 0.8 : 0.25))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.045), in: Capsule())
            .overlay(Capsule().strokeBorder(CompanionPalette.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

struct ShortcutKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.48))
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.075), lineWidth: 0.5))
            .fixedSize()
    }
}

struct CompanionHairline: View {
    var body: some View { Rectangle().fill(CompanionPalette.hairline).frame(height: 0.5) }
}

struct CompanionPageHeader: View {
    var eyebrow: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.8)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }
        }
    }
}

struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .medium)).tracking(1.25)
            .foregroundStyle(Color.white.opacity(0.38))
    }
}

struct EmptyCompanionState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light))
                .foregroundStyle(Color.white.opacity(0.28)).padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                .frame(maxWidth: 430, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 23)
    }
}
