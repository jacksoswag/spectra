import Foundation
import simd

/// Built-in consumer camcorder effects: era/format looks, tape and digital
/// artifacts, auto-system behaviors, and a procedural running-camcorder overlay.
/// Each descriptor's parameter order is the GPU slot order its Metal function
/// reads (see `Camcorder.metal`).
enum CamcorderEffects {
    static let all: [EffectDescriptor] = [
        consumer90s, digital2000s, miniDV, hi8, vhsc,
        interlace, compression, exposurePulse, autofocusHunt, recOSD,
    ]

    // MARK: - Looks

    static let consumer90s = EffectDescriptor(
        id: "camcorder.consumer90s", name: "Consumer 90s", category: .camcorder,
        subtitle: "Warm, soft tape look with grain and interlacing.", icon: "video",
        function: "fx_cam_consumer90s",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.7),
            .slider("grain", "Grain", 0...1, default: 0.4),
            .slider("sharpness", "Sharpness", 0...1, default: 0.5),
        ],
        tags: ["retro", "tape", "90s", "handycam"],
        isAnimated: true)

    static let digital2000s = EffectDescriptor(
        id: "camcorder.digital2000s", name: "Digital 2000s", category: .camcorder,
        subtitle: "Crisp, punchy early-digital handycam.", icon: "video.fill",
        function: "fx_cam_digital2000s",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.7),
            .slider("sharpness", "Sharpness", 0...1, default: 0.6),
        ],
        tags: ["digital", "2000s", "punchy"],
        isAnimated: true)

    static let miniDV = EffectDescriptor(
        id: "camcorder.miniDV", name: "MiniDV", category: .camcorder,
        subtitle: "Clean luma, 4:1:1 chroma, interlaced.", icon: "film",
        function: "fx_cam_miniDV",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.8),
            .slider("sharpness", "Sharpness", 0...1, default: 0.5),
        ],
        tags: ["dv", "tape", "interlaced", "chroma"],
        isAnimated: true)

    static let hi8 = EffectDescriptor(
        id: "camcorder.hi8", name: "Hi8", category: .camcorder,
        subtitle: "Soft analog tape with noise and chroma bleed.", icon: "film.stack",
        function: "fx_cam_hi8",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.7),
            .slider("grain", "Grain", 0...1, default: 0.5),
        ],
        tags: ["analog", "tape", "hi8", "noise"],
        isAnimated: true)

    static let vhsc = EffectDescriptor(
        id: "camcorder.vhsc", name: "VHS-C", category: .camcorder,
        subtitle: "Low-fi tape: heavy bleed, jitter, faded color.", icon: "tv",
        function: "fx_cam_vhsc",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.7),
            .slider("grain", "Grain", 0...1, default: 0.55),
        ],
        tags: ["vhs", "tape", "lofi", "faded"],
        isAnimated: true)

    // MARK: - Artifacts

    static let interlace = EffectDescriptor(
        id: "camcorder.interlace", name: "Interlacing", category: .camcorder,
        subtitle: "Field combing on motion with scanline separation.", icon: "lineweight",
        function: "fx_cam_interlace",
        parameters: [
            .slider("strength", "Strength", 0...1, default: 0.6),
        ],
        tags: ["interlace", "fields", "combing"],
        isAnimated: true)

    static let compression = EffectDescriptor(
        id: "camcorder.compression", name: "Compression Artifacts", category: .camcorder,
        subtitle: "8×8 block quantization and DCT-style banding.", icon: "squareshape.split.3x3",
        function: "fx_cam_compression",
        parameters: [
            .slider("blockiness", "Blockiness", 0...1, default: 0.4),
            .slider("strength", "Strength", 0...1, default: 0.6),
        ],
        tags: ["compression", "blocks", "dct", "bitrate"])

    static let exposurePulse = EffectDescriptor(
        id: "camcorder.exposurePulse", name: "Auto Exposure Pulse", category: .camcorder,
        subtitle: "Auto-iris brightness breathing.", icon: "camera.aperture",
        function: "fx_cam_exposurePulse",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.4),
            .slider("speed", "Speed", 0.1...4, default: 1),
        ],
        tags: ["exposure", "auto-iris", "breathing"],
        isAnimated: true)

    static let autofocusHunt = EffectDescriptor(
        id: "camcorder.autofocusHunt", name: "Autofocus Hunt", category: .camcorder,
        subtitle: "Periodic defocus as the lens hunts.", icon: "camera.metering.center.weighted",
        function: "fx_cam_autofocusHunt",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.5),
            .slider("speed", "Speed", 0.1...4, default: 1),
        ],
        tags: ["focus", "hunt", "defocus", "blur"],
        isAnimated: true)

    // MARK: - On-screen display

    static let recOSD = EffectDescriptor(
        id: "camcorder.recOSD", name: "REC OSD", category: .camcorder,
        subtitle: "REC dot, timecode, battery, date stamp, and zoom readout.", icon: "record.circle",
        function: "fx_cam_recOSD",
        parameters: [
            .toggle("showRec", "Show REC", default: true, group: "Indicators"),
            .toggle("showTimecode", "Show Timecode", default: true, group: "Indicators"),
            .toggle("showBattery", "Show Battery", default: true, group: "Indicators"),
            .toggle("showDate", "Show Date", default: true, group: "Date"),
            .options("dateStyle", "Date Format", ["YYYY-MM-DD", "MM/DD/YYYY", "DD.MM.YYYY"], default: 1, group: "Date"),
            .integer("year", "Year", 1980...2030, default: 1998, group: "Date"),
            .integer("month", "Month", 1...12, default: 7, group: "Date"),
            .integer("day", "Day", 1...31, default: 14, group: "Date"),
            .toggle("showZoom", "Show Zoom", default: false, group: "Zoom"),
            .slider("zoom", "Zoom Factor", 1...20, default: 2.5, unit: "×", group: "Zoom"),
            .toggle("liveClock", "Live Date/Time", default: true, group: "Date"),
        ],
        tags: ["osd", "overlay", "rec", "timecode", "battery", "date", "zoom", "timestamp"],
        isAnimated: true)
}
