import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LighthouseCore

final class BurstAnalysisTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(_ name: String, _ offset: TimeInterval?, camera: String? = "Panasonic DC-S9",
                       folder: String = "/cards/a") -> PhotoAsset {
        PhotoAsset(url: URL(fileURLWithPath: folder).appendingPathComponent(name),
                   metadata: PhotoMetadata(width: 60, height: 40, camera: camera,
                                           capturedAt: offset.map { base.addingTimeInterval($0) }))
    }

    func testGroupsCloseShotsPerCameraAndMergesRAWJPEGPairs() {
        let a = photo("P1.RW2", 0), b = photo("P2.RW2", 0.3), c = photo("P3.RW2", 1.2)
        let lone = photo("P4.RW2", 5), loneJPEG = photo("P4.JPG", 5)
        let otherCamera = photo("X1.JPG", 0.5, camera: "Other")
        let undated = photo("P0.RW2", nil)
        let pairRAW = photo("P9.RW2", 60), pairJPEG = photo("p9.jpg", 60), next = photo("P10.RW2", 60.5)
        let sameNameElsewhere = photo("P10.RW2", 60.5, folder: "/cards/b")
        let groups = BurstGrouping.groups(for: [next, c, pairJPEG, a, lone, undated, loneJPEG, otherCamera, b,
                                                pairRAW, sameNameElsewhere])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].shots, [[a.id], [b.id], [c.id]])
        XCTAssertEqual(groups[1].shots.count, 3, "같은 이름이라도 다른 폴더면 다른 컷")
        XCTAssertEqual(Set(groups[1].shots[0]), [pairRAW.id, pairJPEG.id])
        XCTAssertEqual(Set(groups[1].shots[1] + groups[1].shots[2]), [next.id, sameNameElsewhere.id])
        XCTAssertEqual(groups[0].id, a.id)

        XCTAssertTrue(BurstGrouping.groups(for: [a, photo("Q.RW2", 1.5)]).isEmpty, "1초보다 멀면 따로")
        XCTAssertTrue(BurstGrouping.groups(for: [lone, loneJPEG]).isEmpty, "RAW+JPEG 한 쌍은 연속 촬영이 아니다")
    }

    func testSharpnessPrefersFocusedDetailAndIgnoresBlurredBackground() throws {
        let sharp = try image(width: 400, height: 300) { x, y in (x / 4 + y / 4) % 2 == 0 ? 220 : 40 }
        let soft = try image(width: 400, height: 300) { x, y in
            UInt8(130 + 60 * sin(Double(x) / 18) * cos(Double(y) / 18))
        }
        let halfSharp = try image(width: 400, height: 300) { x, y in
            x < 200 ? ((x / 4 + y / 4) % 2 == 0 ? 220 : 40) : UInt8(130 + 60 * sin(Double(x) / 18))
        }
        let sharpScore = PhotoQualityAnalyzer.sharpness(of: sharp)
        let softScore = PhotoQualityAnalyzer.sharpness(of: soft)
        XCTAssertGreaterThan(sharpScore, softScore * 20)
        XCTAssertGreaterThan(PhotoQualityAnalyzer.sharpness(of: halfSharp), sharpScore * 0.8,
                             "초점 맞은 부분만 있으면 흐린 배경이 점수를 깎지 않는다")
        let flat = try image(width: 3, height: 3) { _, _ in 100 }
        XCTAssertEqual(PhotoQualityAnalyzer.sharpness(of: flat), 0)
    }

    func testNoFacesInSyntheticImage() throws {
        let pattern = try image(width: 320, height: 240) { x, y in (x / 8 + y / 8) % 2 == 0 ? 200 : 60 }
        let faces = PhotoQualityAnalyzer.faceQualities(in: pattern)
        XCTAssertTrue(faces == nil || faces == [], "얼굴이 없거나 Vision을 쓸 수 없어야 한다")
    }

    func testRankingUsesSharpnessThenFacesAndSkipsMissingShots() throws {
        let ids = (0..<5).map { _ in UUID() }
        let group = BurstGroup(shots: [[ids[0]], [ids[1], ids[4]], [ids[2]], [ids[3]]])
        let plain = try XCTUnwrap(BurstRanking.recommend(group, qualities: [
            ids[0]: PhotoQuality(sharpness: 10, faceQualities: []),
            ids[4]: PhotoQuality(sharpness: 30, faceQualities: []),
            ids[2]: PhotoQuality(sharpness: 20, faceQualities: nil)
        ]))
        XCTAssertEqual(plain.bestShot, 1, "RAW+JPEG 컷은 분석한 파일로 판단한다")
        XCTAssertFalse(plain.usedFaces)
        XCTAssertEqual(plain.scores.count, 4)
        XCTAssertEqual(try XCTUnwrap(plain.scores[0]), (1.0 / 3).squareRoot(), accuracy: 1e-9)
        XCTAssertNil(plain.scores[3])

        let faces = try XCTUnwrap(BurstRanking.recommend(group, qualities: [
            ids[0]: PhotoQuality(sharpness: 30, faceQualities: [0.2]),
            ids[1]: PhotoQuality(sharpness: 25, faceQualities: [0.9, 0.8]),
            ids[2]: PhotoQuality(sharpness: 29, faceQualities: [])
        ]))
        XCTAssertTrue(faces.usedFaces)
        XCTAssertEqual(faces.bestShot, 1, "선명도가 조금 낮아도 눈 뜬 컷을 고른다")
        XCTAssertEqual(try XCTUnwrap(faces.scores[1]), 0.5 * (25.0 / 30).squareRoot() + 0.5 * 0.85, accuracy: 1e-9)

        // 실제 CC0 인물 사진 측정값: 눈을 가린 컷은 선명도가 비슷해도 얼굴 품질이 0.46→0.28로 떨어졌다.
        let eyes = try XCTUnwrap(BurstRanking.recommend(group, qualities: [
            ids[0]: PhotoQuality(sharpness: 30, faceQualities: [0.28]),
            ids[1]: PhotoQuality(sharpness: 24, faceQualities: [0.46])
        ]))
        XCTAssertEqual(eyes.bestShot, 1, "20% 더 선명한 눈 감은 컷보다 눈 뜬 컷")

        let tie = try XCTUnwrap(BurstRanking.recommend(group, qualities: [
            ids[2]: PhotoQuality(sharpness: 5, faceQualities: []),
            ids[3]: PhotoQuality(sharpness: 5, faceQualities: [])
        ]))
        XCTAssertEqual(tie.bestShot, 2, "동점이면 먼저 찍은 컷")
        XCTAssertNil(BurstRanking.recommend(group, qualities: [:]))
    }

    func testClosedEyeShotsAreNotRecommendedWhileAnOpenEyeShotExists() throws {
        let ids = (0..<3).map { _ in UUID() }
        let group = BurstGroup(shots: ids.map { [$0] })
        let blinking = BurstRanking.recommend(group, qualities: [
            ids[0]: PhotoQuality(sharpness: 30, faceQualities: [0.6], eyesClosed: true),
            ids[1]: PhotoQuality(sharpness: 20, faceQualities: [0.4], eyesClosed: false),
            ids[2]: PhotoQuality(sharpness: 25, faceQualities: [0.5], eyesClosed: nil)
        ])
        XCTAssertEqual(blinking?.bestShot, 2, "점수가 가장 높아도 눈 감은 컷은 추천하지 않는다")
        XCTAssertEqual(blinking?.closedEyeShots, [0])
        let allClosed = BurstRanking.recommend(group, qualities: [
            ids[0]: PhotoQuality(sharpness: 30, faceQualities: [0.6], eyesClosed: true),
            ids[1]: PhotoQuality(sharpness: 20, faceQualities: [0.4], eyesClosed: true)
        ])
        XCTAssertEqual(allClosed?.bestShot, 0, "모두 눈을 감았으면 점수로 고른다")
        XCTAssertNil(PhotoQualityAnalyzer.eyesClosed(in: try image(width: 64, height: 64) { x, _ in UInt8(x * 4) }),
                     "얼굴이 없으면 판단하지 않는다")
    }

    func testCaptureTimeKeepsSubseconds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: 8, height: 8) { _, _ in 128 }, [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:20 10:15:30",
                kCGImagePropertyExifSubsecTimeOriginal: "25"
            ]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let captured = try XCTUnwrap(ImagePipeline().metadata(for: url).capturedAt)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let whole = try XCTUnwrap(formatter.date(from: "2026:09:20 10:15:30"))
        XCTAssertEqual(captured.timeIntervalSince(whole), 0.25, accuracy: 1e-6)
    }

    private func image(width: Int, height: Int, gray: (Int, Int) -> UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = gray(x, y) } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
