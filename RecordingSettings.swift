import Foundation

enum RecordingResolution: String, CaseIterable, Identifiable {
    case small = "720p"
    case fullHD = "1080p"
    case native = "Native"
    var id: String { rawValue }

    var captureFilter: String {
        switch self {
        case .small: return "scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1"
        case .fullHD: return "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1"
        // Preserve captured pixels. H.264 only needs padding if a dimension is odd.
        case .native: return "pad=ceil(iw/2)*2:ceil(ih/2)*2,setsar=1"
        }
    }
    var crf: Int {
        switch self { case .small: return 28; case .fullHD: return 25; case .native: return 22 }
    }
}

struct RecordingSettings {
    let resolution: RecordingResolution
    let fps: Int

    init?(resolution: RecordingResolution, fpsText: String) {
        guard let fps = Int(fpsText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...120).contains(fps) else { return nil }
        self.resolution = resolution
        self.fps = fps
    }

    var videoRate: Int {
        let base: Double
        switch resolution { case .small: base = 900_000; case .fullHD: base = 2_000_000; case .native: base = 6_000_000 }
        return Int(min(24_000_000, base * max(0.5, Double(fps) / 30)))
    }
}
