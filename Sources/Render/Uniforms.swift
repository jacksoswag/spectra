import Foundation
import simd

/// CPU-side mirror of the `SpectraUniforms` struct defined in `Common.metal`.
///
/// The layout is a flat array of 32-bit floats. Both sides agree on a header of
/// 16 floats followed by 64 effect parameter slots. Because every field is a
/// 4-byte float (and the Metal struct only uses `float`/`float2` members aligned
/// on 4/8-byte boundaries that fall exactly on these indices), copying this flat
/// buffer into the GPU buffer is layout-safe with no padding surprises.
///
/// Header index map (must match `Common.metal`):
/// ```
///  0 resolution.x   1 resolution.y
///  2 texelSize.x    3 texelSize.y
///  4 time           5 frameIndex
///  6 strength       7 opacity
///  8 blendAmount    9 blendMode
/// 10 seed          11 passIndex
/// 12 direction.x   13 direction.y
/// 14 passScale     15 clockSeconds
/// 16..79 params[64]
/// ```
struct SpectraUniforms {
    static let headerFloatCount = 16
    static let paramSlotCount = 64
    static let floatCount = headerFloatCount + paramSlotCount   // 80
    static let byteCount = floatCount * MemoryLayout<Float>.stride

    private(set) var storage = [Float](repeating: 0, count: SpectraUniforms.floatCount)

    // MARK: Header accessors

    var resolution: SIMD2<Float> {
        get { SIMD2(storage[0], storage[1]) }
        set { storage[0] = newValue.x; storage[1] = newValue.y; texelSize = 1 / max(newValue, SIMD2(repeating: 1)) }
    }

    var texelSize: SIMD2<Float> {
        get { SIMD2(storage[2], storage[3]) }
        set { storage[2] = newValue.x; storage[3] = newValue.y }
    }

    var time: Float { get { storage[4] } set { storage[4] = newValue } }
    var frameIndex: Float { get { storage[5] } set { storage[5] = newValue } }
    var strength: Float { get { storage[6] } set { storage[6] = newValue } }
    var opacity: Float { get { storage[7] } set { storage[7] = newValue } }
    var blendAmount: Float { get { storage[8] } set { storage[8] = newValue } }
    var blendMode: Float { get { storage[9] } set { storage[9] = newValue } }
    var seed: Float { get { storage[10] } set { storage[10] = newValue } }
    var passIndex: Float { get { storage[11] } set { storage[11] = newValue } }

    var direction: SIMD2<Float> {
        get { SIMD2(storage[12], storage[13]) }
        set { storage[12] = newValue.x; storage[13] = newValue.y }
    }

    var passScale: Float { get { storage[14] } set { storage[14] = newValue } }

    /// Seconds since local midnight (wall clock); drives the live REC-OSD timecode.
    var clockSeconds: Float { get { storage[15] } set { storage[15] = newValue } }

    // MARK: Parameter slots

    /// Write a single float into parameter slot `index` (0-based).
    mutating func setParam(_ index: Int, _ value: Float) {
        guard index >= 0, index < Self.paramSlotCount else { return }
        storage[Self.headerFloatCount + index] = value
    }

    /// Read a single float from parameter slot `index` (0-based); 0 if out of range.
    func param(_ index: Int) -> Float {
        guard index >= 0, index < Self.paramSlotCount else { return 0 }
        return storage[Self.headerFloatCount + index]
    }

    /// Write a run of floats starting at parameter slot `base`.
    mutating func setParams(at base: Int, _ values: [Float]) {
        for (offset, value) in values.enumerated() {
            setParam(base + offset, value)
        }
    }

    /// Reset all 64 effect parameter slots to zero (header retained).
    mutating func clearParams() {
        for i in Self.headerFloatCount..<Self.floatCount { storage[i] = 0 }
    }

    /// Provide the raw bytes for upload into an `MTLBuffer`.
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        storage.withUnsafeBytes(body)
    }
}
