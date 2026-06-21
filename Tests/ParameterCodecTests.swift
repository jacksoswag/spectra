import XCTest
import simd
@testable import Spectra

/// Parameter codec: round-trips and the short-array decode guard (the bug where a
/// corrupt/older `.spectra` or settings file trapped the process on load).
final class ParameterCodecTests: XCTestCase {
    func testColorRoundTrip() throws {
        let value = ParameterValue.color(SIMD4(0.1, 0.2, 0.3, 1.0))
        let decoded = try JSONStore.decode(ParameterValue.self, from: JSONStore.encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testPointRoundTrip() throws {
        let value = ParameterValue.point(SIMD2(0.25, 0.75))
        let decoded = try JSONStore.decode(ParameterValue.self, from: JSONStore.encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testShortColorArrayThrowsInsteadOfTrapping() {
        let json = Data(#"{"kind":"color","value":[0.1,0.2]}"#.utf8)
        XCTAssertThrowsError(try JSONStore.decode(ParameterValue.self, from: json))
    }

    func testShortPointArrayThrows() {
        let json = Data(#"{"kind":"point","value":[0.5]}"#.utf8)
        XCTAssertThrowsError(try JSONStore.decode(ParameterValue.self, from: json))
    }

    func testShortVector3ArrayThrows() {
        let json = Data(#"{"kind":"vector3","value":[0.5,0.5]}"#.utf8)
        XCTAssertThrowsError(try JSONStore.decode(ParameterValue.self, from: json))
    }
}
