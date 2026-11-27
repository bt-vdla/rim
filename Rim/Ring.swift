import SwiftUI

/// The screen edge as a loop. Position `u` runs clockwise from the top-left corner; each quarter is one
/// side, measured corner-middle to corner-middle so the sides line up with the phases of box breathing.
struct RingPath {
    static let samples = 1440
    let points: [CGPoint]
    let normals: [CGVector]
    let outline: Path

    init(rect: CGRect, radius: CGFloat) {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let centers = [
            CGPoint(x: rect.minX + r, y: rect.minY + r), CGPoint(x: rect.maxX - r, y: rect.minY + r),
            CGPoint(x: rect.maxX - r, y: rect.maxY - r), CGPoint(x: rect.minX + r, y: rect.maxY - r),
        ]
        let starts = [
            CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + r),
            CGPoint(x: rect.maxX - r, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY - r),
        ]
        let ends = [
            CGPoint(x: rect.maxX - r, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY - r),
            CGPoint(x: rect.minX + r, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY + r),
        ]
        let half = .pi * r / 4
        let perSide = Self.samples / 4
        var points: [CGPoint] = []
        points.reserveCapacity(Self.samples)
        for side in 0..<4 {
            let a0 = 5 * Double.pi / 4 + Double(side) * .pi / 2
            let straight = hypot(ends[side].x - starts[side].x, ends[side].y - starts[side].y)
            let length = straight + 2 * half
            for j in 0..<perSide {
                let s = Double(j) / Double(perSide) * length
                if s < half {
                    let a = a0 + s / r
                    points.append(CGPoint(x: centers[side].x + r * cos(a), y: centers[side].y + r * sin(a)))
                } else if s < half + straight {
                    let f = (s - half) / straight
                    points.append(CGPoint(
                        x: starts[side].x + (ends[side].x - starts[side].x) * f,
                        y: starts[side].y + (ends[side].y - starts[side].y) * f
                    ))
                } else {
                    let a = a0 + .pi / 4 + (s - half - straight) / r
                    let c = centers[(side + 1) % 4]
                    points.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                }
            }
        }
        let n = points.count
        normals = (0..<n).map { i in
            let a = points[(i + n - 1) % n], b = points[(i + 1) % n]
            let tx = b.x - a.x, ty = b.y - a.y
            let len = max(hypot(tx, ty), 0.0001)
            return CGVector(dx: -ty / len, dy: tx / len)
        }
        var outline = Path()
        outline.addLines(points)
        outline.closeSubpath()
        self.points = points
        self.outline = outline
    }

    private func index(_ k: Int) -> Int {
        let n = points.count
        return ((k % n) + n) % n
    }

    func point(_ u: Double) -> CGPoint {
        let x = (u - floor(u)) * Double(points.count)
        let i = Int(x), f = x - Double(i)
        let a = points[index(i)], b = points[index(i + 1)]
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    func normal(_ u: Double) -> CGVector {
        normals[index(Int((u - floor(u)) * Double(points.count)))]
    }

    /// The stretch of edge between two positions, the short way round.
    func path(from a: Double, to b: Double) -> Path {
        var d = (b - a).truncatingRemainder(dividingBy: 1)
        if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
        return span(from: a, by: d)
    }

    /// The stretch of edge from `a`, travelling `d` laps (negative runs anticlockwise).
    func span(from a: Double, by d: Double) -> Path {
        var p = Path()
        p.move(to: point(a))
        let n = Double(points.count)
        let ia = a * n, ib = (a + d) * n
        if d >= 0 {
            var k = floor(ia) + 1
            while k < ib { p.addLine(to: points[index(Int(k))]); k += 1 }
        } else {
            var k = ceil(ia) - 1
            while k > ib { p.addLine(to: points[index(Int(k))]); k -= 1 }
        }
        p.addLine(to: point(a + d))
        return p
    }

    /// A stretch of edge pushed `inset` points inward, for lines drawn just inside the light.
    func inset(from a: Double, by d: Double, inset: CGFloat) -> Path {
        var p = Path()
        let steps = max(2, Int(abs(d) * Double(points.count) / 4))
        for k in 0...steps {
            let u = a + d * Double(k) / Double(steps)
            let q = point(u), n = normal(u)
            let c = CGPoint(x: q.x + n.dx * inset, y: q.y + n.dy * inset)
            if k == 0 { p.move(to: c) } else { p.addLine(to: c) }
        }
        return p
    }

    func nearest(to target: CGPoint) -> (u: Double, distance: CGFloat) {
        var best = 0, bestDistance = CGFloat.infinity
        for (i, p) in points.enumerated() {
            let d = hypot(p.x - target.x, p.y - target.y)
            if d < bestDistance { best = i; bestDistance = d }
        }
        return (Double(best) / Double(points.count), bestDistance)
    }

    static func screenRadius(_ proxy: GeometryProxy) -> CGFloat {
        if #available(iOS 27, *), let radii = proxy.concentricCornerRadii, radii.topLeading > 0 {
            return radii.topLeading
        }
        return 55 // ponytail: iOS 26 has no public display radius; this suits recent iPhones.
    }
}

/// The light on the edge, drawn by the `edgeLight` Metal shader: a thick band that swells into a bulge
/// where the breath is, with a Canvas on top for the side highlight and breath dots.
struct RingCanvas: View {
    let ring: RingPath
    let radius: CGFloat
    let colors: [Color]
    let style: RingStyle
    let date: Date
    let trail: Double
    var intensity = 1.0
    var dots = 0
    /// Where earlier holds ended this session, and the best hold ever, as positions on the lap.
    var marks: [Double] = []
    var best: Double?
    /// How much of the session is done, drawn as a fine line just inside the edge.
    var progress: Double?
    /// Lights the whole edge for a moment: holding to begin, and the end of a session.
    var flash = 0.0
    /// Reduce Motion: no travelling light, the whole edge brightens and dims with the breath instead.
    var still = false
    let sample: (Date) -> Moment?

    var body: some View {
        let now = sample(date)
        let level = now.map { 0.42 + 0.58 * $0.full } ?? 0
        let pulse = max(still || now?.pulse == true ? level : 0, flash)
        let bulge = (style == .trace ? 9 : 15) * (0.55 + 0.6 * (now?.full ?? 0))
        let points = now.flatMap { pulse > 0 ? nil : trailPoints($0, level: level) } ?? [0, 0, 0]

        GeometryReader { proxy in
            Rectangle()
                .colorEffect(ShaderLibrary.edgeLight(
                    .float2(proxy.size), .float(radius), .floatArray(points),
                    .color(colors[0]), .color(colors[1]), .color(colors[2]),
                    .float(4), .float(bulge), .float(pulse), .float(intensity)
                ))
        }
        .overlay {
            Canvas { ctx, _ in
                if let side = now?.side, side != .both {
                    let from = side == .left ? 0.75 : 0.25
                    ctx.stroke(ring.span(from: from, by: 0.25),
                               with: .color(.primary.opacity(0.18 * intensity)), lineWidth: 1)
                }
                if let progress, progress > 0 {
                    ctx.stroke(ring.inset(from: 0.125, by: min(progress, 1), inset: 14),
                               with: .color(.primary.opacity(0.28 * intensity)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                for u in marks { tick(&ctx, at: u, color: colors[0].opacity(0.8 * intensity), length: 10) }
                if let best { tick(&ctx, at: best, color: .white.opacity(0.95 * intensity), length: 16) }
                for i in 0..<dots {
                    let u = 0.125 + Double(i % 80) * 0.0125
                    let inset = 22 + CGFloat(i / 80) * 8
                    let p = ring.point(u), n = ring.normal(u)
                    let c = CGPoint(x: p.x + n.dx * inset, y: p.y + n.dy * inset)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6)),
                             with: .color(.primary.opacity(0.5 * intensity)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tick(_ ctx: inout GraphicsContext, at u: Double, color: Color, length: CGFloat) {
        let p = ring.point(u), n = ring.normal(u)
        var path = Path()
        path.move(to: CGPoint(x: p.x + n.dx * 6, y: p.y + n.dy * 6))
        path.addLine(to: CGPoint(x: p.x + n.dx * (6 + length), y: p.y + n.dy * (6 + length)))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    /// Head first, then points back along where the light has been, fading out.
    private func trailPoints(_ now: Moment, level: Double) -> [Float] {
        let n = 32
        let fade = style == .trace ? 0.7 : 2.0
        var out: [Float] = []
        out.reserveCapacity(n * 3)
        for k in 0..<n {
            let f = Double(k) / Double(n)
            let u = k == 0 ? now.u : sample(date.addingTimeInterval(-trail * f))?.u ?? now.u
            let p = ring.point(u)
            out += [Float(p.x), Float(p.y), Float(pow(1 - f, fade) * level)]
        }
        return out
    }
}

/// The `aurora` Metal shader: big, slowly folding fields of the pattern's colours, Apple Music lyrics style.
/// The breath lifts its brightness. With Reduce Motion it holds still.
struct Backdrop: View {
    let colors: [Color]
    let full: Double
    let date: Date
    let still: Bool
    /// Where the light is, and how hard it pulls the colours toward it.
    var head: CGPoint = .zero
    var pull = 0.0
    /// 0 to 1: the end-of-session fall into the light and fade to near-black.
    var collapse = 0.0

    var body: some View {
        let t = still ? 40 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
        GeometryReader { proxy in
            Rectangle()
                .colorEffect(ShaderLibrary.aurora(
                    .float2(proxy.size), .float(t), .float(full), .float(still ? 0 : full),
                    .float2(head), .float(still ? 0 : pull), .float(collapse),
                    .color(colors[0]), .color(colors[1]), .color(colors[2]), .color(colors[3])
                ))
        }
        .ignoresSafeArea()
    }
}

/// The idle ring plays the pattern on a loop so you can see its rhythm before starting.
struct Preview {
    private var steps: [(step: Step, start: Double)] = []
    private(set) var total = 1.0

    init(_ pattern: Pattern, pace: Double) {
        var feed = Feed(pattern: pattern, pace: pace, powerBreaths: 1, rounds: 1)
        let count = pattern.id == .rounds ? 2 : pattern.beats.count
        var t = 0.0
        for _ in 0..<count {
            guard let step = feed.next(), let s = step.seconds else { break }
            steps.append((step, t))
            t += s
        }
        total = max(t, 0.1)
    }

    func moment(_ seconds: Double) -> Moment? {
        let t = seconds - floor(seconds / total) * total
        guard let entry = steps.last(where: { $0.start <= t }) ?? steps.first else { return nil }
        return entry.step.moment(t - entry.start)
    }
}
