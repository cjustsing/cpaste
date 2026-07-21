import AppKit
import CPasteCore
import SwiftUI

enum CPasteTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let backgroundLift = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceHover = Color(nsColor: .selectedControlColor).opacity(0.22)
    static let surfaceSelected = Color(nsColor: .selectedContentBackgroundColor).opacity(0.32)
    static let previewSurface = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let glassTint = Color(nsColor: .windowBackgroundColor)
    static let glassStroke = Color(nsColor: .separatorColor).opacity(0.92)
    static let glassHighlight = Color.white.opacity(0.16)

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textMuted = Color(nsColor: .tertiaryLabelColor)

    static let accent = Color(red: 0.16, green: 0.76, blue: 0.67)
    static let accentSoft = Color(red: 0.08, green: 0.38, blue: 0.34)
    static let amber = Color(red: 0.94, green: 0.63, blue: 0.24)
    static let blue = Color(red: 0.29, green: 0.56, blue: 0.96)
    static let ambientNavy = Color(red: 0.04, green: 0.10, blue: 0.18)
    static let ambientDeepBlue = Color(red: 0.03, green: 0.23, blue: 0.55)
    static let coral = Color(red: 0.94, green: 0.40, blue: 0.34)
    static let violet = Color(red: 0.61, green: 0.45, blue: 0.94)
    static let rose = Color(red: 0.94, green: 0.31, blue: 0.38)

    static func kindColor(_ kind: ClipboardKind) -> Color {
        switch kind {
        case .text:
            return blue
        case .url:
            return coral
        case .file:
            return accent
        case .image:
            return violet
        }
    }
}

struct CPasteIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var isActive = false
    var isDestructive = false
    var isProminent = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.cpasteThemeStyle) private var themeStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .cpasteGlass(
                radius: glassRadius,
                material: isActive || isProminent ? .hudWindow : .menu,
                tint: backgroundTint,
                tintOpacity: backgroundOpacity(configuration.isPressed),
                stroke: border,
                shadowOpacity: isActive || isProminent ? 0.12 : 0.02,
                isInteractive: true,
                liquidTint: liquidTint
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        if isDestructive {
            return CPasteTheme.rose
        }
        return isActive || isProminent ? CPasteTheme.accent : CPasteTheme.textSecondary
    }

    private var backgroundTint: Color {
        isActive || isProminent ? CPasteTheme.accentSoft : CPasteTheme.surface
    }

    private var glassRadius: CGFloat {
        themeStyle == .liquidGlass ? size / 2 : 7
    }

    private var liquidTint: Color? {
        if isDestructive {
            return CPasteTheme.rose.opacity(0.24)
        }
        if isActive || isProminent {
            return CPasteTheme.accent.opacity(0.30)
        }
        return nil
    }

    private var border: Color {
        isActive || isProminent ? CPasteTheme.accent.opacity(0.58) : CPasteTheme.glassStroke
    }

    private func backgroundOpacity(_ isPressed: Bool) -> Double {
        if isActive || isProminent {
            return isPressed ? 0.68 : 0.46
        }
        return isPressed ? 0.76 : 0.42
    }
}

struct CPasteSurface<Content: View>: View {
    var radius: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        content
            .cpasteGlass(radius: radius, material: .hudWindow, tint: CPasteTheme.surface, tintOpacity: 0.58)
    }
}

struct CPasteGlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    @Environment(\.cpasteThemeStyle) private var themeStyle

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *), themeStyle == .liquidGlass {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct CPasteLiquidCanvas: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)

            CPasteTheme.background
                .opacity(reduceTransparency ? 0.96 : 0.36)

            if !reduceTransparency {
                CPasteTheme.ambientNavy.opacity(0.34)

                RadialGradient(
                    colors: [CPasteTheme.ambientDeepBlue.opacity(0.30), Color.clear],
                    center: UnitPoint(x: 0.64, y: 0.28),
                    startRadius: 40,
                    endRadius: 1_280
                )

                RadialGradient(
                    colors: [CPasteTheme.accent.opacity(0.16), Color.clear],
                    center: UnitPoint(x: 0.18, y: 0.34),
                    startRadius: 20,
                    endRadius: 1_100
                )
            }

            LinearGradient(
                colors: [Color.white.opacity(reduceTransparency ? 0.03 : 0.13), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

struct CPasteGlassBackground: View {
    var radius: CGFloat = 8
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var tint: Color = CPasteTheme.glassTint
    var tintOpacity: Double = 0.44
    var stroke: Color = CPasteTheme.glassStroke
    var shadowOpacity: Double = 0.08

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        shape
            .fill(Color.clear)
            .background {
                ZStack {
                    VisualEffectView(material: material, blendingMode: blendingMode)
                    tint.opacity(tintOpacity)
                    Color.white.opacity(0.018)
                }
                .clipShape(shape)
            }
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(CPasteTheme.glassHighlight)
                    .frame(height: 1)
                    .clipShape(shape)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 16, x: 0, y: 8)
    }
}

private struct CPasteGlassModifier: ViewModifier {
    var radius: CGFloat
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var tint: Color
    var tintOpacity: Double
    var stroke: Color
    var shadowOpacity: Double
    var isInteractive: Bool
    var liquidTint: Color?

    @Environment(\.cpasteThemeStyle) private var themeStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), themeStyle == .liquidGlass {
            let glass = liquidTint.map { Glass.regular.tint($0) } ?? .regular
            content
                .glassEffect(
                    glass.interactive(isInteractive),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
        } else {
            content.background {
                CPasteGlassBackground(
                    radius: radius,
                    material: material,
                    blendingMode: blendingMode,
                    tint: tint,
                    tintOpacity: tintOpacity,
                    stroke: stroke,
                    shadowOpacity: shadowOpacity
                )
            }
        }
    }
}

extension View {
    func cpasteGlass(
        radius: CGFloat = 8,
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
        tint: Color = CPasteTheme.glassTint,
        tintOpacity: Double = 0.44,
        stroke: Color = CPasteTheme.glassStroke,
        shadowOpacity: Double = 0.08,
        isInteractive: Bool = false,
        liquidTint: Color? = nil
    ) -> some View {
        modifier(CPasteGlassModifier(
            radius: radius,
            material: material,
            blendingMode: blendingMode,
            tint: tint,
            tintOpacity: tintOpacity,
            stroke: stroke,
            shadowOpacity: shadowOpacity,
            isInteractive: isInteractive,
            liquidTint: liquidTint
        ))
    }
}

private struct CPasteThemeStyleEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppThemeStyle.standard
}

extension EnvironmentValues {
    var cpasteThemeStyle: AppThemeStyle {
        get { self[CPasteThemeStyleEnvironmentKey.self] }
        set { self[CPasteThemeStyleEnvironmentKey.self] = newValue }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
