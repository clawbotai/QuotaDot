import SwiftUI

struct WeatherBackdrop: View {
    let weather: WeatherSnapshot?
    let fallbackHealth: QuotaHealth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.58), .white.opacity(0.04), .clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 310
            )

            WeatherMotionCanvas(
                mood: weather?.mood ?? .cloudy,
                isDay: weather?.isDay ?? true,
                reduceMotion: reduceMotion
            )

            LinearGradient(
                colors: [.white.opacity(0.03), .white.opacity(0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 1.0), value: weather?.mood)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var palette: [Color] {
        guard let weather else {
            return fallbackHealth.backgroundColors.map { $0.opacity(0.88) }
        }
        return weather.mood.atmosphericColors(isDay: weather.isDay)
    }
}

private struct WeatherMotionCanvas: View {
    let mood: WeatherMood
    let isDay: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
                switch mood {
                case .clear:
                    drawClear(in: context, size: size, phase: phase)
                case .partlyCloudy:
                    drawClouds(in: context, size: size, phase: phase, opacity: 0.34, includesSun: true)
                case .cloudy:
                    drawClouds(in: context, size: size, phase: phase, opacity: 0.46, includesSun: false)
                case .fog:
                    drawClouds(in: context, size: size, phase: phase, opacity: 0.26, includesSun: false)
                    drawFog(in: context, size: size, phase: phase)
                case .rain:
                    drawClouds(in: context, size: size, phase: phase, opacity: 0.32, includesSun: false)
                    drawRain(in: context, size: size, phase: phase, storm: false)
                case .storm:
                    drawClouds(in: context, size: size, phase: phase, opacity: 0.38, includesSun: false)
                    drawRain(in: context, size: size, phase: phase, storm: true)
                    drawLightning(in: context, size: size, phase: phase)
                case .snow:
                    drawClouds(in: context, size: size, phase: phase, opacity: 0.30, includesSun: false)
                    drawSnow(in: context, size: size, phase: phase)
                }
            }
        }
    }

    private var frameInterval: TimeInterval {
        guard !reduceMotion else { return 1 }
        return switch mood {
        case .rain, .storm, .snow: 1 / 30
        case .fog: 1 / 20
        case .clear, .partlyCloudy, .cloudy: 1 / 12
        }
    }

    private func drawClear(in context: GraphicsContext, size: CGSize, phase: TimeInterval) {
        let drift = CGFloat(sin(phase / 9)) * 5
        let center = CGPoint(x: size.width * 0.82 + drift, y: 58)
        var glow = context
        glow.addFilter(.blur(radius: 18))
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - 70, y: center.y - 70, width: 140, height: 140)),
            with: .color((isDay ? Color.yellow : Color.white).opacity(0.16))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 33, y: center.y - 33, width: 66, height: 66)),
            with: .color(.white.opacity(isDay ? 0.34 : 0.28))
        )
    }

    private func drawClouds(
        in context: GraphicsContext,
        size: CGSize,
        phase: TimeInterval,
        opacity: Double,
        includesSun: Bool
    ) {
        if includesSun { drawClear(in: context, size: size, phase: phase) }
        let loopWidth = size.width * 1.72 + 180

        var farClouds = context
        farClouds.addFilter(.blur(radius: 15))
        for index in 0..<12 {
            let depth = CGFloat(index % 4) / 3
            let speed = CGFloat(0.34 + Double(index % 5) * 0.13)
            let baseX = CGFloat((index * 137) % max(Int(loopWidth), 1))
            let movingX = (baseX + CGFloat(phase) * speed)
                .truncatingRemainder(dividingBy: loopWidth) - loopWidth * 0.28
            let y = size.height * (0.06 + CGFloat(index % 7) * 0.125) + CGFloat(index % 3) * 7
            let width = size.width * (0.58 + depth * 0.42)
            let height = 34 + depth * 36
            let rect = CGRect(x: movingX - width / 2, y: y - height / 2, width: width, height: height)
            let cloudColor = index.isMultiple(of: 3)
                ? Color(red: 0.34, green: 0.43, blue: 0.54).opacity(opacity * 0.24)
                : Color.white.opacity(opacity * (0.46 + Double(depth) * 0.35))
            farClouds.fill(Path(ellipseIn: rect), with: .color(cloudColor))
            farClouds.fill(Path(ellipseIn: rect.offsetBy(dx: -loopWidth, dy: 0)), with: .color(cloudColor))
        }

        var cloudStreaks = context
        cloudStreaks.addFilter(.blur(radius: 5.5))
        for index in 0..<8 {
            let speed = CGFloat(0.48 + Double(index % 4) * 0.16)
            let offset = (CGFloat(phase) * speed + CGFloat(index * 83))
                .truncatingRemainder(dividingBy: loopWidth) - loopWidth * 0.36
            let y = size.height * (0.10 + CGFloat(index) * 0.105)
            var path = Path()
            path.move(to: CGPoint(x: offset - size.width * 0.85, y: y))
            path.addCurve(
                to: CGPoint(x: offset + size.width * 1.55, y: y + CGFloat(index % 2 == 0 ? 6 : -5)),
                control1: CGPoint(x: offset - size.width * 0.18, y: y - 14),
                control2: CGPoint(x: offset + size.width * 0.78, y: y + 16)
            )
            cloudStreaks.stroke(
                path,
                with: .color(.white.opacity(opacity * (index < 3 ? 0.58 : 0.34))),
                style: StrokeStyle(lineWidth: CGFloat(12 + index * 2), lineCap: .round)
            )
        }
    }

    private func drawRain(in context: GraphicsContext, size: CGSize, phase: TimeInterval, storm: Bool) {
        let count = storm ? 44 : 34
        let speed: CGFloat = storm ? 102 : 76
        for index in 0..<count {
            let depth = CGFloat(index % 3) / 2
            let seedX = CGFloat((index * 83) % max(Int(size.width + 50), 1))
            let seedY = CGFloat((index * 47) % max(Int(size.height + 90), 1))
            let y = (seedY + CGFloat(phase) * speed * (0.84 + depth * 0.24))
                .truncatingRemainder(dividingBy: size.height + 90) - 45
            let x = (seedX - y * 0.12)
                .truncatingRemainder(dividingBy: size.width + 50) - 25
            let length = 12 + depth * 10
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - length * 0.25, y: y + length))
            context.stroke(
                path,
                with: .color(.white.opacity(0.30 + Double(depth) * 0.22)),
                style: StrokeStyle(lineWidth: 0.65 + depth * 0.45, lineCap: .round)
            )
        }
    }

    private func drawSnow(in context: GraphicsContext, size: CGSize, phase: TimeInterval) {
        for index in 0..<38 {
            let depth = CGFloat(index % 4) / 3
            let seedX = CGFloat((index * 59) % max(Int(size.width), 1))
            let seedY = CGFloat((index * 41) % max(Int(size.height + 34), 1))
            let x = (seedX + CGFloat(sin(phase / 2.8 + Double(index))) * (8 + depth * 9))
                .truncatingRemainder(dividingBy: size.width + 16) - 8
            let y = (seedY + CGFloat(phase) * (12 + depth * 13))
                .truncatingRemainder(dividingBy: size.height + 34) - 17
            let diameter = 1.6 + depth * 2.2
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                with: .color(.white.opacity(0.42 + Double(depth) * 0.38))
            )
        }
    }

    private func drawFog(in context: GraphicsContext, size: CGSize, phase: TimeInterval) {
        for index in 0..<6 {
            let y = size.height * (0.20 + CGFloat(index) * 0.12)
            let offset = (CGFloat(phase) * CGFloat(2.2 + Double(index) * 0.35) + CGFloat(index * 61))
                .truncatingRemainder(dividingBy: size.width + 180) - 90
            var path = Path()
            path.move(to: CGPoint(x: offset - size.width, y: y))
            path.addCurve(
                to: CGPoint(x: offset + size.width * 1.4, y: y + 2),
                control1: CGPoint(x: offset - size.width * 0.20, y: y - 8),
                control2: CGPoint(x: offset + size.width * 0.70, y: y + 9)
            )
            context.stroke(
                path,
                with: .color(.white.opacity(0.22)),
                style: StrokeStyle(lineWidth: 8, lineCap: .round)
            )
        }
    }

    private func drawLightning(in context: GraphicsContext, size: CGSize, phase: TimeInterval) {
        let cycle = phase.truncatingRemainder(dividingBy: 8.6)
        let opacity: Double = cycle < 0.08 ? 0.24 : ((cycle > 0.16 && cycle < 0.22) ? 0.13 : 0)
        guard opacity > 0 else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(opacity)))
    }
}
