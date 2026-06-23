import Foundation

/// System effects: stack rows that drive macOS desktop behaviour instead of a GPU
/// pass. Each carries a `controllerKind` and no `passes`, so the chain resolver
/// drops it from the render pipeline and `SystemEffectsController` reconciles it
/// when the row is effectively enabled. The per-row on/off toggle, parameters, and
/// grouping are the same as any other effect.
///
/// These back the Liquid Glass preset's window-transparency, automatic-layout, and
/// adaptive-tint rows. The two yabai-backed effects gate gracefully: when yabai (or
/// its scripting addition, for opacity) is absent they do nothing and the inspector
/// shows a setup note. Adaptive tint is no-privilege and always available.
enum SystemEffects {
    static let all: [EffectDescriptor] = [
        windowTransparency, windowLayout, adaptiveTint, menuBarStyle, dockStyle,
    ]

    /// Per-theme menu-bar styling (MAOE §9), driven through `SystemEffectsController` to a
    /// click-through overlay above the menu bar. The `style` index maps to `MenuBarStyle`.
    static let menuBarStyle = EffectDescriptor(
        id: "system.menuBarStyle", name: "Menu Bar Style", category: .system,
        subtitle: "Per-theme menu-bar treatment (shadow, caption, reflective, pastel).",
        icon: "menubar.rectangle",
        parameters: [
            .options("style", "Style", ["None", "Soft Shadow", "Caption", "Reflective", "Pastel"], default: 1),
        ],
        passes: [],
        tags: ["menu bar", "system", "chrome", "shadow"],
        controllerKind: .menuBarStyle)

    /// Per-theme Dock styling (MAOE §9), driven to a click-through overlay near the Dock.
    /// The `style` index maps to `DockStyle`.
    static let dockStyle = EffectDescriptor(
        id: "system.dockStyle", name: "Dock Style", category: .system,
        subtitle: "Per-theme Dock treatment (grounded shadow, frame, neon outline, pastel).",
        icon: "dock.rectangle",
        parameters: [
            .options("style", "Style", ["None", "Grounded Shadow", "Stage Frame", "Neon Outline", "Matte Pastel", "Reflective"], default: 1),
        ],
        passes: [],
        tags: ["dock", "system", "chrome", "outline"],
        controllerKind: .dockStyle)

    /// Global window opacity (and optional backdrop blur) via yabai. The captured
    /// desktop already composites the now-semi-transparent windows over the
    /// wallpaper, so the look flows through Spectra's normal grade with no extra work.
    static let windowTransparency = EffectDescriptor(
        id: "system.windowTransparency", name: "Window Transparency", category: .system,
        subtitle: "Make every window see-through (via yabai).",
        icon: "macwindow",
        parameters: [
            .slider("activeOpacity", "Focused", 0.2...1.0, default: 0.85,
                    help: "Opacity of the focused window."),
            .slider("normalOpacity", "Unfocused", 0.2...1.0, default: 0.90,
                    help: "Opacity of background windows."),
            .slider("blur", "Backdrop Blur", 0...40, default: 0, unit: "px",
                    help: "Gaussian blur behind transparent windows. Needs the yabai scripting addition."),
        ],
        passes: [],
        tags: ["transparent", "glass", "opacity", "window", "yabai", "see-through"],
        controllerKind: .windowTransparency)

    /// Automatic window sizing and positioning via yabai's tiling. Off (float) by
    /// default in the preset because switching layouts rearranges every managed
    /// window at once; turning the row on tiles, turning it off restores floating.
    static let windowLayout = EffectDescriptor(
        id: "system.windowLayout", name: "Window Layout", category: .system,
        subtitle: "Auto-tile and position windows (via yabai).",
        icon: "rectangle.split.2x1",
        parameters: [
            .options("layout", "Layout", ["Tile (BSP)", "Stack", "Float (off)"], default: 0,
                     help: "How windows on the current Space are arranged."),
            .slider("gap", "Window Gap", 0...40, default: 8, unit: "px"),
            .slider("padding", "Screen Padding", 0...40, default: 8, unit: "px"),
        ],
        passes: [],
        tags: ["tiling", "layout", "yabai", "position", "size", "arrange", "bsp"],
        controllerKind: .windowLayout)

    /// A click-through desktop-level tint, derived from the display's wallpaper, that
    /// shows through transparent windows for a cohesive glass tone. No privileges.
    static let adaptiveTint = EffectDescriptor(
        id: "system.adaptiveTint", name: "Adaptive Tint", category: .system,
        subtitle: "Tint the desktop behind glass to match it.",
        icon: "drop.halffull",
        parameters: [
            .slider("strength", "Strength", 0...1, default: 1.0,
                    help: "How strongly the gap tint matches the windows. 1.0 mirrors the windows' own opacity."),
            .slider("smoothing", "Smoothing", 0...1, default: 0.5,
                    help: "How slowly the tint colour follows the windows as they change."),
        ],
        passes: [],
        tags: ["tint", "desktop", "glass", "ambient", "wallpaper"],
        controllerKind: .adaptiveTint)
}
