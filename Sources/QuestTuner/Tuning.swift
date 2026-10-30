import Foundation

struct TextureSize: Equatable {
    let width: Int
    let height: Int

    /// Quest 3 display resolution per eye.
    static let panel = TextureSize(width: 2064, height: 2208)

    var megapixels: Double { Double(width * height) / 1_000_000 }
    var panelPercent: Int {
        Int((Double(width * height) / Double(TextureSize.panel.width * TextureSize.panel.height) * 100).rounded())
    }
}

/// Values written to the headset as debug.oculus.* system properties.
struct Tuning: Equatable {
    var gpuLevel = 7
    var cpuLevel = 6
    var refreshRate = 90
    var foveation = 4
    var textureWidth = 2560
    var textureHeight = 2816

    // Quest 3 clocks per level. GPU level 7 is undocumented but reaches the top kernel OPP.
    static let gpuMHz = [285, 350, 456, 492, 545, 599, 640, 690]
    static let cpuGHz = [0.69, 1.09, 1.38, 1.65, 1.92, 2.05, 2.21]
    static let refreshRates = [72, 80, 90, 120]
    static let foveationNames = ["Off", "Low", "Medium", "High", "High top"]

    /// Eye texture sizes at 10:11 (the aspect of 2560×2816), width in steps of 128,
    /// height rounded to a multiple of 16.
    static let textureSizes: [TextureSize] = stride(from: 1536, through: 3072, by: 128).map { w in
        TextureSize(width: w, height: Int((Double(w) * 1.1 / 16).rounded()) * 16)
    }

    static let kickoffHeadroom = "0.25e-3"

    var textureIndex: Int {
        get {
            Tuning.textureSizes.indices.min {
                abs(Tuning.textureSizes[$0].width - textureWidth) < abs(Tuning.textureSizes[$1].width - textureWidth)
            } ?? 0
        }
        set {
            textureWidth = Tuning.textureSizes[newValue].width
            textureHeight = Tuning.textureSizes[newValue].height
        }
    }

    var refreshIndex: Int {
        get { Tuning.refreshRates.firstIndex(of: refreshRate) ?? Tuning.refreshRates.count - 2 }
        set { refreshRate = Tuning.refreshRates[newValue] }
    }

    var texture: TextureSize { TextureSize(width: textureWidth, height: textureHeight) }

    var setpropCommand: String {
        [
            "setprop debug.oculus.gpuLevel \(gpuLevel)",
            "setprop debug.oculus.cpuLevel \(cpuLevel)",
            "setprop debug.oculus.refreshRate \(refreshRate)",
            "setprop debug.oculus.foveation.level \(foveation)",
            "setprop debug.oculus.textureWidth \(textureWidth)",
            "setprop debug.oculus.textureHeight \(textureHeight)",
            "setprop debug.oculus.extraKickoffHeadroom \(Tuning.kickoffHeadroom)",
        ].joined(separator: "; ")
    }

    static let propertyNames = [
        "gpuLevel", "cpuLevel", "refreshRate", "foveation.level",
        "textureWidth", "textureHeight", "extraKickoffHeadroom",
    ]
}

enum Preset: String, CaseIterable, Identifiable {
    case highQuality = "High Quality"
    case highPerformance = "High Performance"

    var id: String { rawValue }

    var tuning: Tuning {
        switch self {
        case .highQuality: Tuning(textureWidth: 2560, textureHeight: 2816)
        case .highPerformance: Tuning(textureWidth: 2048, textureHeight: 2256)
        }
    }

    var systemImage: String {
        switch self {
        case .highQuality: "sparkles"
        case .highPerformance: "bolt.fill"
        }
    }

    var subtitle: String {
        let t = tuning
        return "\(t.textureWidth)×\(t.textureHeight) · \(t.texture.panelPercent)% panel"
    }

    var detail: String {
        let t = tuning
        return "GPU \(Tuning.gpuMHz[t.gpuLevel]) MHz · \(t.refreshRate) Hz"
    }
}

/// Meta apps that nothing in VR depends on while a game runs.
let nonEssentialMetaApps = [
    "com.oculus.browser",
    "com.android.settings",
    "com.oculus.guidebook",
    "com.oculus.metacam",
    "com.oculus.explore",
    "com.oculus.tv",
    "com.oculus.helpcenter",
    "com.oculus.accountscenter",
    "com.oculus.vrprivacycheckup",
    "com.oculus.facebook",
    "com.oculus.igvr",
    "com.oculus.MontereyNUX",
    "com.oculus.socialplatform",
]
