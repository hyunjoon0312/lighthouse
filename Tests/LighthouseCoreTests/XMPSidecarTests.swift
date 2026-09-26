import Foundation
import XCTest
@testable import LighthouseCore

final class XMPSidecarTests: XCTestCase {
    private func values(_ xml: String, _ path: String) throws -> [String] {
        let document = try XMLDocument(xmlString: xml)
        return try document.nodes(forXPath: path).compactMap(\.stringValue)
    }

    func testDocumentCarriesMarksAndEscapesText() throws {
        var photo = PhotoAsset(url: URL(fileURLWithPath: "/photos/P1000123.RW2"))
        photo.rating = 3
        photo.colorLabel = .red
        photo.keywords = ["바다", "A&B <x>"]
        photo.caption = "제주 \"협재\""
        XCTAssertEqual(XMPSidecar.url(for: photo).path, "/photos/P1000123.xmp")
        let xml = XMPSidecar.document(for: photo)
        XCTAssertEqual(try values(xml, "//*[local-name()='Description']/@*[local-name()='Rating']"), ["3"])
        XCTAssertEqual(try values(xml, "//*[local-name()='Description']/@*[local-name()='Label']"), ["Red"])
        XCTAssertEqual(try values(xml, "//*[local-name()='subject']//*[local-name()='li']"), ["바다", "A&B <x>"])
        XCTAssertEqual(try values(xml, "//*[local-name()='description']//*[local-name()='li']"), ["제주 \"협재\""])
        photo.flag = .reject
        XCTAssertEqual(try values(XMPSidecar.document(for: photo), "//*[local-name()='Description']/@*[local-name()='Rating']"),
                       ["-1"], "제외는 별점 -1")
    }

    func testWritesOnlyItsOwnSidecars() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var photo = PhotoAsset(url: folder.appendingPathComponent("A.RW2"))
        photo.rating = 2
        XCTAssertEqual(XMPSidecar.write(photo), .written)
        XCTAssertEqual(XMPSidecar.write(photo), .unchanged, "같은 내용이면 다시 쓰지 않는다")
        photo.rating = 4
        XCTAssertEqual(XMPSidecar.write(photo), .written, "Lighthouse가 쓴 것은 고쳐 쓴다")

        let foreign = PhotoAsset(url: folder.appendingPathComponent("B.RW2"))
        let camera = Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Adobe XMP\"/>".utf8)
        try camera.write(to: XMPSidecar.url(for: foreign))
        XCTAssertEqual(XMPSidecar.write(foreign), .foreign)
        XCTAssertEqual(try Data(contentsOf: XMPSidecar.url(for: foreign)), camera, "다른 프로그램의 사이드카는 그대로")

        let missing = PhotoAsset(url: folder.appendingPathComponent("없는 폴더/C.RW2"))
        guard case .failed = XMPSidecar.write(missing) else { return XCTFail("원본 폴더가 없으면 실패") }
    }
}
