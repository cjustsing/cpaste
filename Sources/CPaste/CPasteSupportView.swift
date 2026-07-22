import AppKit
import SwiftUI

struct CPasteSupportView: View {
    @Environment(\.cpasteThemeStyle) private var themeStyle
    @State private var paymentMethod: SupportPaymentMethod

    let onClose: () -> Void

    init(
        initialPaymentMethod: SupportPaymentMethod = .wechat,
        onClose: @escaping () -> Void = {}
    ) {
        _paymentMethod = State(initialValue: initialPaymentMethod)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 10) {
                Text(CPasteL10n.text(
                    "如果 CPaste 帮到了你，可以自愿请开发者喝杯咖啡。",
                    "If CPaste helps you, you can voluntarily buy the developer a coffee."
                ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CPasteTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $paymentMethod) {
                    ForEach(SupportPaymentMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityLabel(CPasteL10n.text("选择赞赏方式", "Choose a support method"))

                paymentCode

                Text(CPasteL10n.text(
                    "完全自愿，不解锁任何功能，也不影响软件使用或后续更新。",
                    "Support is entirely optional and does not unlock features or affect updates."
                ))
                .font(.system(size: 11))
                .foregroundStyle(CPasteTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if usesLiquidGlassLayout {
                CPasteLiquidCanvas()
            } else {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    CPasteTheme.background.opacity(0.88)
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CPasteTheme.rose)
                .frame(width: 30, height: 30)
                .cpasteGlass(
                    radius: 7,
                    tint: CPasteTheme.rose.opacity(0.18),
                    tintOpacity: 0.48,
                    stroke: CPasteTheme.rose.opacity(0.34),
                    shadowOpacity: 0.02
                )

            Text(CPasteL10n.text("支持 CPaste", "Support CPaste"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CPasteTheme.textPrimary)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPasteTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(CPasteTheme.previewSurface.opacity(0.72), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(CPasteTheme.separator, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .contentShape(Circle())
            .help(CPasteL10n.text("关闭", "Close"))
            .accessibilityLabel(CPasteL10n.text("关闭赞赏窗口", "Close support window"))
        }

        if usesLiquidGlassLayout {
            CPasteGlassGroup(spacing: 10) {
                content
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .cpasteGlass(radius: 20, shadowOpacity: 0.18)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
        } else {
            content
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background {
                    CPasteGlassBackground(
                        radius: 0,
                        material: .headerView,
                        tint: CPasteTheme.backgroundLift,
                        tintOpacity: 0.54,
                        stroke: Color.clear,
                        shadowOpacity: 0.06
                    )
                }
        }
    }

    @ViewBuilder
    private var paymentCode: some View {
        if let image = SupportAssetLoader.image(for: paymentMethod) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 216, height: 216)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
                .accessibilityLabel(paymentMethod.accessibilityLabel)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.system(size: 42, weight: .medium))
                Text(CPasteL10n.text("未能加载收款码", "Unable to load the payment code"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(CPasteTheme.textSecondary)
            .frame(width: 232, height: 232)
            .cpasteGlass(radius: 12, tintOpacity: 0.48)
        }
    }

    private var usesLiquidGlassLayout: Bool {
        if #available(macOS 26.0, *) {
            return themeStyle == .liquidGlass
        }
        return false
    }
}

enum SupportPaymentMethod: String, CaseIterable, Identifiable {
    case wechat
    case alipay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wechat:
            return CPasteL10n.text("微信", "WeChat Pay")
        case .alipay:
            return CPasteL10n.text("支付宝", "Alipay")
        }
    }

    var accessibilityLabel: String {
        CPasteL10n.text("\(title)赞赏二维码", "\(title) support QR code")
    }

    fileprivate var resourceName: String {
        switch self {
        case .wechat:
            return "wechat-support-qr"
        case .alipay:
            return "alipay-support-qr"
        }
    }

    fileprivate var resourceExtension: String {
        "png"
    }
}

private enum SupportAssetLoader {
    static func image(for method: SupportPaymentMethod) -> NSImage? {
        if let bundledURL = Bundle.main.url(
            forResource: method.resourceName,
            withExtension: method.resourceExtension,
            subdirectory: "Support"
        ), let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Support", isDirectory: true)
            .appendingPathComponent("\(method.resourceName).\(method.resourceExtension)", isDirectory: false)
        return NSImage(contentsOf: developmentURL)
    }
}
