import Foundation

/// Settings of the headset's own video recording (Record video in the Quest menu),
/// written as debug.oculus.capture.* system properties. They reset when the headset restarts.
struct VideoCapture: Equatable {
    var width = 1024
    var height = 1024
    var bitrate = 5_000_000
    /// Off: the recording runs at half the display refresh rate.
    var fullRate = false

    struct Size: Equatable {
        let width: Int
        let height: Int
        let short: String
    }

    /// Ordered by pixel count. 1024×1024 is the system default.
    static let sizes = [
        Size(width: 1280, height: 720, short: "720p"),
        Size(width: 1024, height: 1024, short: "1024²"),
        Size(width: 1920, height: 1080, short: "1080p"),
        Size(width: 1440, height: 1440, short: "1440²"),
        Size(width: 1600, height: 1600, short: "1600²"),
        Size(width: 2560, height: 1440, short: "1440p"),
    ]

    /// Mbit/s. 5 is the system default.
    static let bitratesMbps = [5, 10, 20, 30, 40, 60]

    var sizeIndex: Int {
        // A size set elsewhere maps to the listed size closest in pixel count.
        get {
            Self.sizes.firstIndex { $0.width == width && $0.height == height }
                ?? Self.sizes.indices.min {
                    abs(Self.sizes[$0].width * Self.sizes[$0].height - width * height)
                        < abs(Self.sizes[$1].width * Self.sizes[$1].height - width * height)
                } ?? 1
        }
        set {
            width = Self.sizes[newValue].width
            height = Self.sizes[newValue].height
        }
    }

    var bitrateIndex: Int {
        get {
            Self.bitratesMbps.indices.min {
                abs(Self.bitratesMbps[$0] * 1_000_000 - bitrate) < abs(Self.bitratesMbps[$1] * 1_000_000 - bitrate)
            } ?? 0
        }
        set { bitrate = Self.bitratesMbps[newValue] * 1_000_000 }
    }

    /// Approximate file size per minute of recording.
    var megabytesPerMinute: Int { bitrate * 60 / 8 / 1_000_000 }

    var setpropCommand: String {
        [
            "setprop debug.oculus.capture.width \(width)",
            "setprop debug.oculus.capture.height \(height)",
            "setprop debug.oculus.capture.bitrate \(bitrate)",
            "setprop debug.oculus.fullRateCapture \(fullRate ? 1 : 0)",
        ].joined(separator: "; ")
    }

    static let propertyNames = ["capture.width", "capture.height", "capture.bitrate", "fullRateCapture"]
}
