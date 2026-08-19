import SwiftUI

extension QuotaHealth {
    var progressColor: Color {
        switch self {
        case .healthy: Color(red: 0.08, green: 0.50, blue: 0.96)
        case .warning: Color(red: 0.96, green: 0.61, blue: 0.13)
        case .critical: Color(red: 0.96, green: 0.29, blue: 0.25)
        case .unknown: .gray
        }
    }

    var backgroundColors: [Color] {
        return switch self {
        case .healthy: [Color(red: 0.91, green: 0.96, blue: 0.95), Color(red: 0.96, green: 0.94, blue: 0.82), Color(red: 0.86, green: 0.92, blue: 0.98)]
        case .warning: [Color(red: 0.94, green: 0.96, blue: 0.88), Color(red: 0.98, green: 0.91, blue: 0.68), Color(red: 0.92, green: 0.90, blue: 0.82)]
        case .critical: [Color(red: 0.96, green: 0.90, blue: 0.84), Color(red: 0.96, green: 0.78, blue: 0.72), Color(red: 0.88, green: 0.84, blue: 0.84)]
        case .unknown: [Color.gray.opacity(0.18), Color.gray.opacity(0.10)]
        }
    }

    var shadowColor: Color {
        switch self { case .healthy: .blue.opacity(0.13); case .warning: .yellow.opacity(0.18); case .critical: .red.opacity(0.18); case .unknown: .black.opacity(0.10) }
    }
    var color: Color {
        switch self {
        case .healthy: .mint
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    var foregroundColor: Color {
        switch self {
        case .healthy: .primary
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .healthy: LinearGradient(colors: [Color(red: 0.04, green: 0.20, blue: 0.20), Color(red: 0.04, green: 0.10, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .warning: LinearGradient(colors: [Color(red: 0.28, green: 0.16, blue: 0.04), Color(red: 0.12, green: 0.08, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .critical: LinearGradient(colors: [Color(red: 0.30, green: 0.06, blue: 0.09), Color(red: 0.13, green: 0.04, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .unknown: LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.17), Color(red: 0.07, green: 0.08, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension ProviderUsage {
    var accent: Color {
        switch providerId.lowercased() {
        case "claude": Color(red: 0.93, green: 0.39, blue: 0.22)
        case "kimi": Color(red: 0.46, green: 0.35, blue: 0.94)
        case "glm": Color(red: 0.30, green: 0.35, blue: 0.95)
        case "deepseek": Color(red: 0.20, green: 0.43, blue: 0.92)
        default: Color(red: 0.20, green: 0.48, blue: 0.96)
        }
    }

    var softPalette: [Color] {
        let health = QuotaHealth(remaining: [session?.remainingPercent, weekly?.remainingPercent].compactMap { $0 }.min())
        switch health {
        case .warning:
            return [Color(red: 1.00, green: 0.98, blue: 0.87), Color(red: 0.98, green: 0.93, blue: 0.78)]
        case .critical:
            return [Color(red: 1.00, green: 0.94, blue: 0.92), Color(red: 0.98, green: 0.84, blue: 0.83)]
        default:
            return switch providerId.lowercased() {
            case "claude":
                [Color(red: 1.00, green: 0.96, blue: 0.91), Color(red: 0.95, green: 0.91, blue: 0.98)]
            case "kimi":
                [Color(red: 0.95, green: 0.94, blue: 1.00), Color(red: 0.91, green: 0.94, blue: 1.00)]
            case "deepseek":
                [Color(red: 0.91, green: 0.96, blue: 1.00), Color(red: 0.88, green: 0.93, blue: 1.00)]
            default:
                [Color(red: 0.92, green: 0.97, blue: 1.00), Color(red: 0.90, green: 0.94, blue: 1.00)]
            }
        }
    }
}

extension WeatherMood {
    func atmosphericColors(isDay: Bool) -> [Color] {
        if !isDay {
            return switch self {
            case .clear:
                [Color(red: 0.08, green: 0.16, blue: 0.30), Color(red: 0.14, green: 0.25, blue: 0.43), Color(red: 0.24, green: 0.31, blue: 0.47)]
            case .partlyCloudy:
                [Color(red: 0.12, green: 0.20, blue: 0.33), Color(red: 0.22, green: 0.30, blue: 0.42), Color(red: 0.28, green: 0.35, blue: 0.46)]
            case .cloudy, .fog:
                [Color(red: 0.17, green: 0.23, blue: 0.31), Color(red: 0.30, green: 0.36, blue: 0.44), Color(red: 0.24, green: 0.30, blue: 0.38)]
            case .rain, .storm:
                [Color(red: 0.08, green: 0.15, blue: 0.24), Color(red: 0.20, green: 0.28, blue: 0.37), Color(red: 0.13, green: 0.21, blue: 0.31)]
            case .snow:
                [Color(red: 0.22, green: 0.31, blue: 0.42), Color(red: 0.43, green: 0.52, blue: 0.61), Color(red: 0.31, green: 0.40, blue: 0.50)]
            }
        }
        return switch self {
        case .clear:
            [Color(red: 0.38, green: 0.67, blue: 0.95), Color(red: 0.69, green: 0.84, blue: 0.98), Color(red: 0.98, green: 0.88, blue: 0.66)]
        case .partlyCloudy:
            [Color(red: 0.48, green: 0.66, blue: 0.84), Color(red: 0.77, green: 0.84, blue: 0.91), Color(red: 0.91, green: 0.86, blue: 0.75)]
        case .cloudy:
            [Color(red: 0.52, green: 0.63, blue: 0.74), Color(red: 0.72, green: 0.79, blue: 0.86), Color(red: 0.60, green: 0.69, blue: 0.78)]
        case .fog:
            [Color(red: 0.62, green: 0.69, blue: 0.75), Color(red: 0.84, green: 0.87, blue: 0.89), Color(red: 0.70, green: 0.76, blue: 0.80)]
        case .rain:
            [Color(red: 0.30, green: 0.45, blue: 0.59), Color(red: 0.51, green: 0.62, blue: 0.72), Color(red: 0.36, green: 0.50, blue: 0.62)]
        case .storm:
            [Color(red: 0.17, green: 0.27, blue: 0.38), Color(red: 0.34, green: 0.45, blue: 0.56), Color(red: 0.23, green: 0.34, blue: 0.46)]
        case .snow:
            [Color(red: 0.67, green: 0.82, blue: 0.93), Color(red: 0.94, green: 0.97, blue: 1.00), Color(red: 0.77, green: 0.87, blue: 0.94)]
        }
    }
}

extension View {
    @ViewBuilder
    func quotaLiquidGlass(cornerRadius: CGFloat) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
#else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
#endif
    }

    @ViewBuilder
    func quotaCompactGlass(cornerRadius: CGFloat) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
#else
        self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
#endif
    }

    @ViewBuilder
    func quotaContentGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
                }
        }
#else
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(0.07), lineWidth: 0.75)
            }
#endif
    }
}
