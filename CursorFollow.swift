import Foundation
import CoreGraphics
import CoreMedia

struct CursorSample {
    let time: Double
    let x: Double
    let y: Double
}

/// Two independent, time-based easing stages. The intermediate target chases
/// the cursor, and the view chases that target. Exact integration makes the
/// response independent of capture/output frame rate.
struct EaseAxis {
    var target: Double
    var position: Double
    static let targetTime = 0.10
    static let viewTime = 0.18

    var velocity: Double { (target - position) / Self.viewTime }

    mutating func advance(toward cursor: Double, dt: Double) {
        guard dt > 0 else { return }
        let a = exp(-dt / Self.targetTime)
        let b = exp(-dt / Self.viewTime)
        let oldTarget = target
        position = cursor + (position - cursor) * b
            + (oldTarget - cursor) * Self.targetTime / (Self.targetTime - Self.viewTime) * (a - b)
        target = cursor + (oldTarget - cursor) * a
    }
}

struct MotionKnot {
    let position: CGPoint
    let velocity: CGPoint
}

struct CursorMotion {
    let samples: [CursorSample]
    private let knots: [MotionKnot]
    private let step = 1.0 / 120.0

    init(samples: [CursorSample]) {
        self.samples = samples
        func raw(_ time: Double, _ index: inout Int) -> CGPoint {
            guard let first = samples.first, let last = samples.last else { return CGPoint(x: 0.5, y: 0.5) }
            if time <= first.time { return CGPoint(x: first.x, y: first.y) }
            if time >= last.time { return CGPoint(x: last.x, y: last.y) }
            while index + 1 < samples.count - 1 && samples[index + 1].time < time { index += 1 }
            let a = samples[index], b = samples[index + 1]
            let u = max(0, min(1, (time - a.time) / max(b.time - a.time, 0.000001)))
            return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        }
        var index = 0
        let first = raw(0, &index)
        // Starting both stages at the actual initial cursor avoids an opening
        // pan from the center of the screen.
        var x = EaseAxis(target: first.x, position: first.x)
        var y = EaseAxis(target: first.y, position: first.y)
        var result = [MotionKnot(position: first, velocity: .zero)]
        let end = max(0, samples.last?.time ?? 0) + 2
        let count = Int(ceil(end / step))
        for tick in 1...max(1, count) {
            let cursor = raw((Double(tick) - 0.5) * step, &index)
            x.advance(toward: cursor.x, dt: step)
            y.advance(toward: cursor.y, dt: step)
            result.append(MotionKnot(position: CGPoint(x: x.position, y: y.position),
                                     velocity: CGPoint(x: x.velocity, y: y.velocity)))
        }
        knots = result
    }

    func position(at time: Double) -> CGPoint {
        let frame = max(0, time) / step
        let index = min(Int(frame), knots.count - 1)
        guard index + 1 < knots.count else { return knots[index].position }
        let u = frame - Double(index), v = 1-u
        let a = knots[index], b = knots[index + 1]
        // Bézier control handles use the view's velocity. Adjacent segments
        // share that velocity, so interpolation adds no extra easing stage.
        func axis(_ p0: Double, _ velocity0: Double, _ p3: Double, _ velocity1: Double) -> Double {
            let p1 = p0 + velocity0 * step / 3
            let p2 = p3 - velocity1 * step / 3
            return max(0, min(1, v*v*v*p0 + 3*v*v*u*p1 + 3*v*u*u*p2 + u*u*u*p3))
        }
        return CGPoint(x: axis(a.position.x, a.velocity.x, b.position.x, b.velocity.x),
                       y: axis(a.position.y, a.velocity.y, b.position.y, b.velocity.y))
    }

    func commands(width: Int, height: Int, duration: Double, fps: Int) -> String {
        // Work at double resolution for half-output-pixel pan increments.
        let cropW = Int(Double(width * 2) / 1.05) / 2 * 2
        let cropH = Int(Double(height * 2) / 1.05) / 2 * 2
        var result = ""
        for frame in 0..<max(1, Int(ceil(duration * Double(fps)))) {
            let time = Double(frame) / Double(fps)
            let p = position(at: time)
            // Crop-origin movement is opposite to visible image movement.
            // Invert it so the picture translates in the cursor's direction.
            let x = Double(width * 2 - cropW) * (1.0 - max(0.0, min(1.0, Double(p.x))))
            let y = Double(height * 2 - cropH) * (1.0 - max(0.0, min(1.0, Double(p.y))))
            result += String(format: "%.6f crop@follow x %.4f, crop@follow y %.4f;\n", locale: Locale(identifier: "en_US_POSIX"), max(0, time - 0.000001), x, y)
        }
        return result
    }

    static func filter(width: Int, height: Int, fps: Int, commandFile: URL) -> String {
        let cropW = Int(Double(width * 2) / 1.05) / 2 * 2
        let cropH = Int(Double(height * 2) / 1.05) / 2 * 2
        // Command files live in an app-generated UUID directory with a simple
        // basename; a relative path avoids FFmpeg filter escaping of user paths.
        return "fps=\(fps),scale=\(width*2):\(height*2):flags=bicubic,sendcmd=f=\(commandFile.lastPathComponent),crop@follow=\(cropW):\(cropH):0:0:exact=1,scale=\(width):\(height):flags=lanczos,setsar=1"
    }
}

final class CursorTracker {
    private(set) var samples: [CursorSample] = []
    private var timer: Timer?
    private var origin: Double?
    private var bounds = CGRect.zero

    func start(screenName: String) throws {
        guard let index = Int(screenName.replacingOccurrences(of: "Capture screen ", with: "")) else {
            throw NSError(domain: "CursorFollow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not identify the selected display."])
        }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            throw NSError(domain: "CursorFollow", code: 2, userInfo: [NSLocalizedDescriptionKey: "No active display found."])
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success, index < Int(count) else {
            throw NSError(domain: "CursorFollow", code: 3, userInfo: [NSLocalizedDescriptionKey: "The display changed. Refresh and try again."])
        }
        bounds = CGDisplayBounds(displays[index])
        origin = nil
        samples = []
        sample()
        timer = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @discardableResult func alignClock(captureOrigin: Double) -> Bool {
        guard origin == nil, captureOrigin.isFinite, captureOrigin > 0 else { return false }
        // The FFmpeg timestamp offset and cursor samples share the AVFoundation
        // host clock. Log delivery/encoding latency never enters this mapping.
        origin = captureOrigin
        return true
    }

    private func sample() {
        guard let point = CGEvent(source: nil)?.location, bounds.width > 0, bounds.height > 0 else { return }
        samples.append(CursorSample(time: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                                    x: max(0, min(1, (point.x - bounds.minX) / bounds.width)),
                                    y: max(0, min(1, (point.y - bounds.minY) / bounds.height))))
    }

    func stop() -> CursorMotion? {
        sample()
        timer?.invalidate()
        timer = nil
        guard let origin else { return nil }
        return CursorMotion(samples: samples.map { CursorSample(time: $0.time - origin, x: $0.x, y: $0.y) })
    }
}

struct CaptureTimestampParser {
    /// FFmpeg's input timestamp offset is an integer in AV_TIME_BASE units
    /// (microseconds). Parse that integer, not rounded pkt_pts_time text and
    /// never the wall time at which this message reaches the app.
    static func origin(from line: String) -> Double? {
        guard line.contains("demuxer+ffmpeg ->"), line.contains("type:video") else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"\boff:(-?\d+)\b"#)
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let offset = Double(ns.substring(with: match.range(at: 1))), offset < 0 else { return nil }
        return -offset / 1_000_000
    }
}
