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

        var missing = PhotoAsset(url: folder.appendingPathComponent("없는 폴더/C.RW2"))
        missing.rating = 1
        guard case .failed = XMPSidecar.write(missing) else { return XCTFail("원본 폴더가 없으면 실패") }

        var plain = PhotoAsset(url: folder.appendingPathComponent("D.RW2"))
        plain.flag = .pick
        XCTAssertEqual(XMPSidecar.write(plain), .unchanged, "적을 표시가 없으면(선택 표시는 XMP 항목이 없음) 만들지 않는다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecar.url(for: plain).path))
        photo.rating = 0
        XCTAssertEqual(XMPSidecar.write(photo), .written, "이미 쓴 사이드카는 표시를 모두 지워도 별점 0으로 고쳐 쓴다")
        XCTAssertTrue(try String(contentsOf: XMPSidecar.url(for: photo), encoding: .utf8).contains("xmp:Rating=\"0\""))
    }

    /// 다른 앱이 Lighthouse 사이드카에 항목을 더해 저장하면 `CreatorTool`이 남아 있어도 덮어쓰지 않는다.
    func testSidecarEditedByAnotherAppIsLeftAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var photo = PhotoAsset(url: folder.appendingPathComponent("A.RW2"))
        photo.rating = 2
        photo.colorLabel = .purple
        photo.keywords = ["바다", "A&B <x>"]
        photo.caption = "제주 \"협재\""
        XCTAssertEqual(XMPSidecar.write(photo), .written)
        photo.rating = 4
        XCTAssertEqual(XMPSidecar.write(photo), .written, "키워드·설명이 든 우리 사이드카도 알아보고 고쳐 쓴다")

        let target = XMPSidecar.url(for: photo)
        let ours = try String(contentsOf: target, encoding: .utf8)
        let developed = ours.replacingOccurrences(
            of: "xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
            with: "xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n    xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"\n    crs:Exposure2012=\"+0.50\"")
        XCTAssertNotEqual(developed, ours)
        try developed.write(to: target, atomically: true, encoding: .utf8)
        photo.rating = 5
        XCTAssertEqual(XMPSidecar.write(photo), .foreign)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), developed, "다른 앱이 더한 보정값은 그대로")

        let reformatted = XMPSidecar.document(for: photo).replacingOccurrences(of: "\n    xmp:Rating", with: " xmp:Rating")
        try reformatted.write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(XMPSidecar.write(photo), .foreign, "모양이 달라진 파일은 누가 고쳤는지 알 수 없어 두고 알린다")
    }
}
