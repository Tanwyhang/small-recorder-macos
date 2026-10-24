import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

struct Device: Identifiable, Hashable {
    let id: String
    let name: String
}

final class Recorder: NSObject, ObservableObject, NSApplicationDelegate {
    @Published var screens: [Device] = []
    @Published var microphones: [Device] = []
    @Published var screen = ""
    @Published var microphone = "none"
    @Published var resolution = RecordingResolution(rawValue: UserDefaults.standard.string(forKey: "resolution") ?? "1080p") ?? .fullHD {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
    }
    @Published var frameRate = UserDefaults.standard.string(forKey: "frameRate") ?? "30" {
        didSet { UserDefaults.standard.set(frameRate, forKey: "frameRate") }
    }
    @Published var customFPS = UserDefaults.standard.string(forKey: "customFPS") ?? "48" {
        didSet { UserDefaults.standard.set(customFPS, forKey: "customFPS") }
    }
    var settings: RecordingSettings? { RecordingSettings(resolution: resolution, fpsText: frameRate == "custom" ? customFPS : frameRate) }
    @Published var followCursor = true
    @Published var recording = false
    @Published var busy = false
    @Published var status = "Choose a screen, then press Start."
    @Published var elapsed = 0
    @Published var fileSize = "0 MB"
    @Published var lastFile: URL?
    private var process: Process?
    private var input: Pipe?
    private var log: FileHandle?
    private var timer: Timer?
    private var started = Date()
    private var stopping = false
    private let cursorTracker = CursorTracker()
    private var captureMessages: Pipe?
    private var captureText = ""
    private var renderDirectory: URL?
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Small Recorder", isDirectory: true)
    let ffmpeg: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/ffmpeg" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/ffmpeg"
    }()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if process != nil {
            quitWhenDone = true
            if recording { stop() }
            return .terminateLater
        }
        return .terminateNow
    }
    private var quitWhenDone = false
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }

    func refresh() {
        guard !recording && !busy else { return }
        busy = true
        status = "Finding screens and microphones…"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: self.ffmpeg)
            task.arguments = ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]
            let pipe = Pipe()
            task.standardError = pipe
            task.standardOutput = FileHandle.nullDevice
            var output = ""
            do {
                try task.run()
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                task.waitUntilExit()
            } catch {
                DispatchQueue.main.async { self.busy = false; self.status = "FFmpeg could not start. Install it with brew install ffmpeg, then reopen the app. \(error.localizedDescription)" }
                return
            }
            var displays: [Device] = []
            var mics: [Device] = []
            var audio = false
            let pattern = try! NSRegularExpression(pattern: #"\] \[(\d+)\] (.+)$"#)
            for line in output.components(separatedBy: .newlines) {
                if line.contains("AVFoundation audio devices:") { audio = true }
                let ns = line as NSString
                if let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let device = Device(id: ns.substring(with: match.range(at: 1)), name: ns.substring(with: match.range(at: 2)))
                    if audio { mics.append(device) }
                    else if device.name.hasPrefix("Capture screen") { displays.append(device) }
                }
            }
            let foundScreens = displays
            let foundMics = mics
            DispatchQueue.main.async {
                self.screens = foundScreens
                self.microphones = foundMics
                if !foundScreens.contains(where: { $0.id == self.screen }) { self.screen = foundScreens.first?.id ?? "" }
                self.busy = false
                self.status = foundScreens.isEmpty ? "No screen found. Check Screen Recording permission, then Refresh." : "Ready. Recordings save to Movies → Small Recorder."
            }
        }
    }

    func start() {
        guard !recording && !busy && !screen.isEmpty else { return }
        busy = true
        status = "Checking screen access…"
        Task { @MainActor in
            do {
                // Ask the capture API itself. The legacy CG preflight can
                // disagree with Settings for a rebuilt, locally signed app.
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                self.busy = false
                self.beginCapture()
            } catch {
                self.busy = false
                self.status = "Screen access unavailable. Enable Small Recorder in Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
            }
        }
    }

    private func beginCapture() {
        guard !recording && !busy && !screen.isEmpty else { return }
        guard let settings else { status = "Enter a whole frame rate from 1 to 120 fps."; return }
        if microphone != "none" && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.start() }
                    else { self.status = "Microphone permission is off. Enable it in System Settings, or select No audio." }
                }
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = folder.appendingPathComponent("Recording \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).mp4")
            let shouldFollow = followCursor
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("small-recorder-\(UUID().uuidString)", isDirectory: true)
            if shouldFollow {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                renderDirectory = directory
                try cursorTracker.start(screenName: screens.first(where: { $0.id == screen })?.name ?? "")
            }
            let captureURL = shouldFollow ? directory.appendingPathComponent("capture.mp4") : url
            let logURL = folder.appendingPathComponent("last-recording.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            let fps = String(settings.fps)
            let rate = String(settings.videoRate)
            let buffer = String(settings.videoRate * 2)
            task.arguments = ["-hide_banner", "-loglevel", shouldFollow ? "info" : "warning", "-debug_ts", "-f", "avfoundation", "-framerate", fps,
                              "-capture_cursor", "1", "-i", "\(screen):\(microphone)",
                              "-r", fps,
                              "-vf", settings.resolution.captureFilter,
                              "-c:v", "libx264", "-preset", "veryfast", "-crf", String(settings.resolution.crf),
                              "-maxrate", rate, "-bufsize", buffer, "-pix_fmt", "yuv420p",
                              "-c:a", "aac", "-b:a", "64k", "-ac", "1",
                              "-fs", "27000000", "-movflags", "+faststart", captureURL.path]
            input = Pipe()
            task.standardInput = input
            captureText = ""
            captureMessages = Pipe()
            task.standardError = captureMessages
            task.standardOutput = FileHandle.nullDevice
            captureMessages?.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.captureText += text
                    while let newline = self.captureText.firstIndex(of: "\n") {
                        let line = String(self.captureText[..<newline])
                        self.captureText.removeSubrange(...newline)
                        if shouldFollow, let origin = CaptureTimestampParser.origin(from: line) {
                            if self.cursorTracker.alignClock(captureOrigin: origin) {
                                let first = self.cursorTracker.samples.first?.time ?? origin
                                let message = String(format: "Cursor sync: source origin %.6f, first sample %.6f, capture startup %.6f seconds\n", origin, first, origin - first)
                                try? self.log?.write(contentsOf: Data(message.utf8))
                            }
                        }
                        // Keep diagnostics small; timestamp tracing is consumed
                        // only for clock synchronization, not persisted per frame.
                        if !line.contains(" -> ") && !line.contains(" <- ") {
                            try? self.log?.write(contentsOf: Data((line + "\n").utf8))
                        }
                    }
                }
            }
            task.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.timer?.invalidate()
                    self.timer = nil
                    self.captureMessages?.fileHandleForReading.readabilityHandler = nil
                    self.captureMessages = nil
                    let motion = self.cursorTracker.stop()
                    self.recording = false
                    self.input = nil
                    if finished.terminationStatus == 0 && shouldFollow, let motion {
                        self.busy = true
                        self.status = "Rendering smooth cursor follow…"
                        self.renderFollow(capture: captureURL, output: url, motion: motion, settings: settings)
                    } else if finished.terminationStatus == 0 && shouldFollow {
                        // Do not publish an effect with guessed synchronization.
                        self.preserveCapture(captureURL, output: url)
                    } else {
                        self.finish(output: url, success: finished.terminationStatus == 0)
                    }
                }
            }
            try task.run()
            process = task
            recording = true
            stopping = false
            started = Date()
            elapsed = 0
            fileSize = "0 MB"
            status = "Recording… Stop when finished."
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.elapsed = Int(Date().timeIntervalSince(self.started))
                if let attributes = try? FileManager.default.attributesOfItem(atPath: captureURL.path), let bytes = attributes[.size] as? NSNumber {
                    self.fileSize = String(format: "%.1f MB", bytes.doubleValue / 1_000_000)
                }
            }
        } catch {
            _ = cursorTracker.stop()
            cleanupRender()
            try? log?.close()
            log = nil
            status = "Could not start: \(error.localizedDescription)"
        }
    }
    func stop() {
        guard recording && !stopping else { return }
        stopping = true
        busy = true
        status = "Finishing MP4…"
        do { try input?.fileHandleForWriting.write(contentsOf: Data("q\n".utf8)) }
        catch { process?.interrupt() }
    }
    func requestQuit() { NSApp.terminate(nil) }

    private func cleanupRender() {
        if let directory = renderDirectory { try? FileManager.default.removeItem(at: directory) }
        renderDirectory = nil
    }

    private func finish(output: URL, success: Bool, message: String? = nil) {
        try? log?.close()
        log = nil
        process = nil
        busy = false
        recording = false
        if success {
            lastFile = output
            if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path), let bytes = attributes[.size] as? NSNumber {
                fileSize = String(format: "%.1f MB", bytes.doubleValue / 1_000_000)
            }
        }
        status = message ?? (success ? "Saved. Ready for another recording." : "Recording failed. Open the recording log for details.")
        stopping = false
        cleanupRender()
        if quitWhenDone { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    private func renderFollow(capture: URL, output: URL, motion: CursorMotion, settings: RecordingSettings) {
        let fps = settings.fps
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: capture)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw NSError(domain: "CursorFollow", code: 4, userInfo: [NSLocalizedDescriptionKey: "No video track found."])
                }
                let size = try await track.load(.naturalSize)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite && duration > 0, let directory = self.renderDirectory else {
                    throw NSError(domain: "CursorFollow", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid capture duration."])
                }
                let width = Int(size.width), height = Int(size.height)
                let commandFile = directory.appendingPathComponent("motion.txt")
                let commands = motion.commands(width: width, height: height, duration: duration, fps: fps)
                try commands.write(to: commandFile, atomically: true, encoding: .utf8)
                // Budget the full duration, rather than truncating the rendered
                // clip with -fs. Reserve 5 MB for audio, muxing and VBV bursts.
                let maxVideoRate = max(16000, min(settings.videoRate, Int(25_000_000 * 8 / duration) - 64_000))
                let renderer = Process()
                renderer.executableURL = URL(fileURLWithPath: self.ffmpeg)
                renderer.currentDirectoryURL = directory
                renderer.arguments = ["-hide_banner", "-loglevel", "warning", "-nostdin", "-i", capture.path,
                                      "-map", "0:v:0", "-map", "0:a?", "-vf", CursorMotion.filter(width: width, height: height, fps: fps, commandFile: commandFile),
                                      "-c:v", "libx264", "-preset", "fast", "-crf", String(settings.resolution.crf),
                                      "-maxrate", "\(maxVideoRate)", "-bufsize", "\(maxVideoRate * 2)", "-pix_fmt", "yuv420p",
                                      "-c:a", "copy", "-movflags", "+faststart", output.path]
                renderer.standardError = self.log
                renderer.standardOutput = FileHandle.nullDevice
                renderer.terminationHandler = { [weak self] task in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if task.terminationStatus == 0 { self.finish(output: output, success: true) }
                        else { self.preserveCapture(capture, output: output) }
                    }
                }
                try renderer.run()
                self.process = renderer
            } catch {
                self.preserveCapture(capture, output: output)
            }
        }
    }

    private func preserveCapture(_ capture: URL, output: URL) {
        // Never discard a good capture just because the optional effect failed.
        let fallback = output.deletingPathExtension().appendingPathExtension("original.mp4")
        do {
            try FileManager.default.moveItem(at: capture, to: fallback)
            finish(output: fallback, success: true, message: "Cursor follow failed; your original recording was saved. Check last-recording.log.")
        } catch {
            // Keep the temporary folder for recovery if moving it also fails.
            renderDirectory = nil
            finish(output: capture, success: true, message: "Cursor follow failed. Original retained at \(capture.path)")
        }
    }
    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
    func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

struct ContentView: View {
    @ObservedObject var recorder: Recorder
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: recorder.recording ? "record.circle.fill" : "video.circle.fill")
                    .font(.system(size: 35)).foregroundStyle(recorder.recording ? .red : .blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Small Recorder").font(.title2.bold())
                    Text("Simple screen recording. Smaller MP4s.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Screen", selection: $recorder.screen) {
                        if recorder.screens.isEmpty { Text("No screen found").tag("") }
                        ForEach(recorder.screens) { Text($0.name).tag($0.id) }
                    }
                    Picker("Audio", selection: $recorder.microphone) {
                        Text("No audio").tag("none")
                        ForEach(recorder.microphones) { Text($0.name).tag($0.id) }
                    }
                    Picker("Resolution", selection: $recorder.resolution) {
                        ForEach(RecordingResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame rate", selection: $recorder.frameRate) {
                        Text("15 fps").tag("15")
                        Text("24 fps").tag("24")
                        Text("30 fps").tag("30")
                        Text("60 fps").tag("60")
                        Text("Custom…").tag("custom")
                    }
                    if recorder.frameRate == "custom" {
                        HStack {
                            Text("Custom FPS")
                            TextField("1–120", text: $recorder.customFPS)
                                .textFieldStyle(.roundedBorder).frame(width: 90)
                                .accessibilityLabel("Custom frames per second")
                            Text("fps").foregroundStyle(.secondary)
                        }
                    }
                    if recorder.settings == nil {
                        Text("Enter a whole frame rate from 1 to 120 fps.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("Native keeps the full captured resolution. Higher resolution or FPS reaches the size limit sooner. Capture speed depends on your display and Mac.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Follow cursor · 5% zoom", isOn: $recorder.followCursor)
                    Text("Double-smoothed Bézier motion, applied after Stop & Save.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Automatically stops near 27 MB to stay under your 30 MB limit. Microphone audio only; system audio is not captured.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }.disabled(recorder.recording || recorder.busy)
            HStack {
                Text(String(format: "%02d:%02d", recorder.elapsed / 60, recorder.elapsed % 60))
                    .font(.system(.title, design: .monospaced)).monospacedDigit()
                Text(recorder.fileSize).foregroundStyle(.secondary)
                Spacer()
                Button(recorder.recording ? "Stop & Save" : "Start Recording") {
                    recorder.recording ? recorder.stop() : recorder.start()
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(recorder.recording ? .red : .blue)
                .disabled(recorder.busy || (!recorder.recording && (recorder.screen.isEmpty || recorder.settings == nil)))
            }
            Text(recorder.status).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 38, alignment: .topLeading)
            HStack {
                Button("Recordings") { recorder.openFolder() }
                if let url = recorder.lastFile {
                    Button("Show Last") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
                Button("Permissions") { recorder.openPermissions() }
                Button("Refresh") { recorder.refresh() }.disabled(recorder.recording || recorder.busy)
            }.font(.callout)
        }.padding(24).frame(width: 510)
    }
}

@main struct SmallRecorderApp: App {
    @NSApplicationDelegateAdaptor(Recorder.self) var recorder
    var body: some Scene {
        WindowGroup {
            ContentView(recorder: recorder).onAppear { recorder.refresh() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) { Button("Quit Small Recorder") { recorder.requestQuit() }.keyboardShortcut("q") }
            CommandGroup(replacing: .newItem) { }
        }
    }
}
