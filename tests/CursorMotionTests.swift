import Foundation

@main struct CursorMotionTests {
    static func main() throws {
        for resolution in RecordingResolution.allCases {
            for fps in [1, 15, 24, 30, 48, 60, 120] {
                let settings = RecordingSettings(resolution: resolution, fpsText: String(fps))!
                precondition(settings.fps == fps && settings.resolution == resolution, "Resolution and FPS must be independent")
            }
        }
        for invalid in ["", "0", "121", "-1", "29.97", "abc"] {
            precondition(RecordingSettings(resolution: .native, fpsText: invalid) == nil)
        }
        precondition(!RecordingResolution.native.captureFilter.contains("scale="), "Native must never downscale")
        let still = CursorMotion(samples: [CursorSample(time: 0, x: 0.2, y: 0.8), CursorSample(time: 4, x: 0.2, y: 0.8)])
        for t in stride(from: 0.0, to: 5.0, by: 0.01) {
            let p = still.position(at: t)
            precondition(abs(p.x - 0.2) < 1e-10 && abs(p.y - 0.8) < 1e-10, "Stationary cursor must not drift")
        }
        let motion = CursorMotion(samples: [
            CursorSample(time: 0, x: 0, y: 0), CursorSample(time: 0.5, x: 0, y: 0),
            CursorSample(time: 0.51, x: 1, y: 1), CursorSample(time: 1.5, x: 1, y: 1),
            CursorSample(time: 1.51, x: 0, y: 0), CursorSample(time: 3, x: 0, y: 0)])
        var maxStep = 0.0
        var previous = motion.position(at: 0)
        for t in stride(from: 0.0, to: 4.0, by: 1.0/60) {
            let p = motion.position(at: t)
            precondition((0...1).contains(p.x) && (0...1).contains(p.y), "Motion must never overshoot screen edges")
            maxStep = max(maxStep, abs(p.x - previous.x))
            previous = p
        }
        precondition(maxStep < 0.12, "A pointer jump must ease over multiple frames")
        precondition(abs(motion.position(at: 4).x) < 0.0001, "View must settle after the cursor stops")
        // Cascading the two stages softens the initial response and keeps
        // moving after a reversal while the intermediate target catches up.
        var eased = EaseAxis(target: 0, position: 0)
        eased.advance(toward: 1, dt: 1.0/60)
        precondition(eased.position > 0 && eased.position < eased.target && eased.target < 1)
        precondition(eased.position < 0.01, "First view movement must be gentler than the intermediate target")
        var responses: [Double] = []
        for fps in [15, 30, 60, 120] {
            var state = EaseAxis(target: 0, position: 0)
            for _ in 0..<fps { state.advance(toward: 1, dt: 1.0/Double(fps)) }
            responses.append(state.position)
        }
        precondition(responses.max()! - responses.min()! < 1e-12, "Smoothing must not change with frame rate")
        let jump = CursorMotion(samples: [CursorSample(time: 0, x: 0, y: 0),
                                         CursorSample(time: 0.5, x: 0, y: 0),
                                         CursorSample(time: 0.500001, x: 1, y: 1),
                                         CursorSample(time: 3, x: 1, y: 1)])
        precondition(jump.position(at: 0.49).x == 0, "Smoothing must never anticipate a future cursor jump")
        precondition(jump.position(at: 0.55).x < 0.08, "View should glide into the jump")
        precondition(jump.position(at: 0.8).x > 0.5 && jump.position(at: 1.5).x > 0.99)
        // Check velocity at Bézier joins, including the retarget/reversal.
        let h = 0.000001
        for tick in 1..<400 {
            let t = Double(tick) / 120
            let a = motion.position(at: t-h).x, b = motion.position(at: t).x, c = motion.position(at: t+h).x
            precondition(abs((b-a)/h - (c-b)/h) < 0.001, "Bézier joins must preserve velocity")
        }
        let logLine = "[vist#0:0/rawvideo] demuxer+ffmpeg -> ist_index:0:0 type:video pkt_pts:0 off:-1234567890123 off_time:-1.23457e+06"
        precondition(CaptureTimestampParser.origin(from: logLine) == 1234567.890123, "Use exact source-clock microseconds, not rounded text or delivery time")
        precondition(CaptureTimestampParser.origin(from: logLine.replacingOccurrences(of: "type:video", with: "type:audio")) == nil)
        precondition(CaptureTimestampParser.origin(from: "out_time_us=2000000") == nil, "Encoder progress must not set the capture clock")
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let file = directory.appendingPathComponent("motion.txt")
        try motion.commands(width: 1280, height: 720, duration: 4, fps: 30).write(to: file, atomically: true, encoding: .utf8)
        let filter = CursorMotion.filter(width: 1280, height: 720, fps: 30, commandFile: file)
        try filter.write(to: directory.appendingPathComponent("filter.txt"), atomically: true, encoding: .utf8)
        let native = RecordingSettings(resolution: .native, fpsText: "48")!
        let hd = RecordingSettings(resolution: .fullHD, fpsText: "24")!
        try "\(native.resolution.captureFilter)\n\(hd.resolution.captureFilter)".write(to: directory.appendingPathComponent("settings-filters.txt"), atomically: true, encoding: .utf8)
        print("PASS: independent resolution/FPS combinations and custom FPS validation")
        print("PASS: two-stage easing, frame-rate independence, no anticipation/drift/overshoot, continuous Bézier velocity, settled endpoint")
    }
}
