import Foundation
import simd

/// Built-in sharpening and detail effects. Each descriptor's parameter order is
/// the GPU slot order its Metal function reads (see `Sharpen.metal`).
enum SharpenEffects {
    static let all: [EffectDescriptor] = [
        sharpen, unsharpMask, clarity, localContrast, detail, edge,
    ]

    static let sharpen = EffectDescriptor(
        id: "sharpen.sharpen", name: "Sharpen", category: .sharpen,
        subtitle: "Classic 3×3 high-pass crisping.", icon: "triangle",
        function: "fx_sharpen_sharpen",
        parameters: [.slider("amount", "Amount", 0...2, default: 0.6)],
        tags: ["detail", "crisp", "highpass"])

    static let unsharpMask = EffectDescriptor(
        id: "sharpen.unsharpMask", name: "Unsharp Mask", category: .sharpen,
        subtitle: "Add back detail above a blurred reference.", icon: "circle.dashed",
        function: "fx_sharpen_unsharpMask",
        parameters: [
            .slider("amount", "Amount", 0...3, default: 1.0),
            .slider("radius", "Radius", 1...12, default: 3.0, unit: "px"),
        ],
        tags: ["detail", "usm"])

    static let clarity = EffectDescriptor(
        id: "sharpen.clarity", name: "Clarity", category: .sharpen,
        subtitle: "Midtone local-contrast punch.", icon: "sparkles",
        function: "fx_sharpen_clarity",
        parameters: [.slider("amount", "Amount", 0...2, default: 0.5)],
        tags: ["midtone", "contrast", "pop"])

    static let localContrast = EffectDescriptor(
        id: "sharpen.localContrast", name: "Local Contrast", category: .sharpen,
        subtitle: "Large-radius luma contrast boost.", icon: "circle.lefthalf.filled",
        function: "fx_sharpen_localContrast",
        parameters: [
            .slider("amount", "Amount", 0...2, default: 0.5),
            .slider("radius", "Radius", 8...64, default: 24.0, unit: "px"),
        ],
        tags: ["contrast", "hdr", "luma"])

    static let detail = EffectDescriptor(
        id: "sharpen.detail", name: "Detail Enhancement", category: .sharpen,
        subtitle: "Multi-radius high-frequency recovery.", icon: "wand.and.rays",
        function: "fx_sharpen_detail",
        parameters: [.slider("amount", "Amount", 0...2, default: 0.7)],
        tags: ["detail", "texture", "multiscale"])

    static let edge = EffectDescriptor(
        id: "sharpen.edge", name: "Edge Enhancement", category: .sharpen,
        subtitle: "Sobel edges added back to the image.", icon: "scribble.variable",
        function: "fx_sharpen_edge",
        parameters: [.slider("amount", "Amount", 0...3, default: 0.8)],
        tags: ["edge", "sobel", "outline"])
}
