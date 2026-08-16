import SwiftUI

/// Single source of truth for the app's visual language: a flat, near-black
/// "dev tool" look — solid cards with thin borders, solid accent fills, no
/// glass/blur material and no glow. Every surface in the app reads as one
/// consistent system rather than a patchwork of default AppKit chrome.
enum Theme {
    // MARK: Palette

    static let bg = Color(red: 0.043, green: 0.043, blue: 0.05)

    static let accent = Color(red: 0.25, green: 0.45, blue: 0.95)     // blue
    static let accent2 = Color(red: 0.66, green: 0.42, blue: 1.0)     // violet
    static let accent3 = Color(red: 0.28, green: 0.86, blue: 0.92)    // cyan

    /// Historically a gradient; kept flat (both stops the same color) so
    /// every existing `.fill(Theme.accentGradient)` call site renders as a
    /// solid fill without needing to touch each one individually.
    static let accentGradient = LinearGradient(
        colors: [accent, accent],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.38)

    static let hairline = Color.white.opacity(0.08)
    static let hairlineBright = Color.white.opacity(0.14)

    static let panelFill = Color.white.opacity(0.035)

    // MARK: Semantic colors

    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return accent3
        case "POST": return Color(red: 0.45, green: 0.85, blue: 0.55)
        case "PUT", "PATCH": return Color(red: 0.98, green: 0.72, blue: 0.35)
        case "DELETE": return Color(red: 1.0, green: 0.42, blue: 0.5)
        default: return accent2
        }
    }

    static func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case 300..<400: return accent3
        case 400..<500: return Color(red: 0.98, green: 0.72, blue: 0.35)
        default: return Color(red: 1.0, green: 0.42, blue: 0.5)
        }
    }
}

// MARK: - Ambient background

/// Flat near-black backdrop with a faint dot grid — the plain, static
/// surface every card sits on. No motion, no blurred color blobs.
struct AmbientBackground: View {
    var body: some View {
        Theme.bg
            .overlay(DotGrid())
            .ignoresSafeArea()
    }
}

private struct DotGrid: View {
    private let spacing: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                        with: .color(.white.opacity(0.045))
                    )
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

// MARK: - Glass panel

/// Named `GlassPanel` for call-site continuity, but no longer glass: a flat
/// card fill with a thin solid border, no material blur, no shadow.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 18
    var borderOpacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline.opacity(borderOpacity), lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 18, borderOpacity: Double = 1.0) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, borderOpacity: borderOpacity))
    }
}

// MARK: - Buttons

/// Pill button used across the toolbar. `prominent` renders a solid accent
/// fill (used for the primary Start/Stop action); otherwise it's a flat,
/// bordered pill — no blur, no glow.
struct GlassButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.panelFill))
            }
            .overlay(
                Capsule().strokeBorder(prominent ? Color.clear : Theme.hairlineBright, lineWidth: 1)
            )
            .foregroundStyle(prominent ? .white : Theme.textPrimary)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Small icon-only button (Clear, Copy, etc) — flat circle, thin border.
struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(Theme.panelFill, in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairlineBright, lineWidth: 1))
            .foregroundStyle(Theme.textPrimary)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// No chrome at all — bare text/icon, just a color and a press state. Used
/// for the primary transport controls (Record/Pause/Clear), which read as
/// plain labels rather than buttons in the reference UI this was matched
/// to, unlike the bordered icon buttons elsewhere in the same toolbar.
struct PlainTextButtonStyle: ButtonStyle {
    var tint: Color = Theme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Small building blocks

/// Colored, bordered chip used for HTTP methods and status codes.
struct Chip: View {
    let text: String
    let color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(filled ? color.opacity(0.9) : color.opacity(0.14))
            }
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.5), lineWidth: 1))
            .foregroundStyle(filled ? .white : color)
    }
}

/// A pulsing status dot, used to show "capture is live".
struct PulseDot: View {
    let color: Color
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.8 : 1)
                    .opacity(pulse ? 0 : 0.8)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
