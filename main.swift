import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

struct Device: Identifiable, Hashable {
    let id: String
    let name: String
}

final class Recorder: NSObject, ObservableObject, NSApplicationDelegate {
    @Published var screens: [Device] = []
    @Published var microphones: [Device] = []
    @Published var screen = ""
    @Published var microphone = "none"
    @Published var clearQuality = false
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
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Small Recorder", isDirectory: true)
    let ffmpeg: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/ffmpeg" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/ffmpeg"
    }()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recording {
            quitWhenDone = true
            stop()
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
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            status = "Allow Small Recorder in System Settings → Privacy & Security → Screen Recording, then reopen the app."
            return
        }
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
            let logURL = folder.appendingPathComponent("last-recording.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            let fps = clearQuality ? "30" : "15"
            let bounds = clearQuality ? "1920:1080" : "1280:720"
            let rate = clearQuality ? "2000k" : "900k"
            let buffer = clearQuality ? "4000k" : "1800k"
            task.arguments = ["-hide_banner", "-loglevel", "warning", "-f", "avfoundation", "-framerate", fps,
                              "-capture_cursor", "1", "-i", "\(screen):\(microphone)",
                              "-vf", "scale=\(bounds):force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1",
                              "-c:v", "libx264", "-preset", "veryfast", "-crf", clearQuality ? "25" : "28",
                              "-maxrate", rate, "-bufsize", buffer, "-pix_fmt", "yuv420p",
                              "-c:a", "aac", "-b:a", "64k", "-ac", "1",
                              "-fs", "27000000", "-movflags", "+faststart", url.path]
            input = Pipe()
            task.standardInput = input
            task.standardError = log
            task.standardOutput = FileHandle.nullDevice
            task.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.timer?.invalidate()
                    self.timer = nil
                    try? self.log?.close()
                    self.log = nil
                    self.recording = false
                    self.busy = false
                    self.process = nil
                    self.input = nil
                    if finished.terminationStatus == 0 {
                        self.lastFile = url
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let bytes = attributes[.size] as? NSNumber {
                            self.fileSize = String(format: "%.1f MB", bytes.doubleValue / 1_000_000)
                        }
                        self.status = self.stopping ? "Saved. Ready for another recording." : "Saved automatically at the size limit. Start again for another clip."
                    } else {
                        self.status = "Recording failed. Check permissions, then open the recording log for details."
                    }
                    self.stopping = false
                    if self.quitWhenDone { NSApp.reply(toApplicationShouldTerminate: true) }
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
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let bytes = attributes[.size] as? NSNumber {
                    self.fileSize = String(format: "%.1f MB", bytes.doubleValue / 1_000_000)
                }
            }
        } catch {
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
    func requestQuit() {
        if recording { quitWhenDone = true; stop() }
        else { NSApp.terminate(nil) }
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
                    Picker("Quality", selection: $recorder.clearQuality) {
                        Text("Small · 720p · 15 fps").tag(false)
                        Text("Clear · 1080p · 30 fps").tag(true)
                    }
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
                .disabled(recorder.busy || (!recorder.recording && recorder.screen.isEmpty))
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
