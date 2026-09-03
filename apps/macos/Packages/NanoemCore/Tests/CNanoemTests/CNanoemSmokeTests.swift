import CNanoem
import XCTest

final class CNanoemSmokeTests: XCTestCase {
    func testCreatesAndDestroysMotion() throws {
        var status = nanoem_status_t(NANOEM_STATUS_SUCCESS)
        let factory = try XCTUnwrap(nanoemUnicodeStringFactoryCreateCF(&status))
        defer { nanoemUnicodeStringFactoryDestroyCF(factory) }
        XCTAssertEqual(status, nanoem_status_t(NANOEM_STATUS_SUCCESS))

        let motion = try XCTUnwrap(nanoemMotionCreate(factory, &status))
        defer { nanoemMotionDestroy(motion) }

        XCTAssertEqual(status, nanoem_status_t(NANOEM_STATUS_SUCCESS))
    }
}
