import CoreGraphics
import CoreImage
import ImageIO
import LighthouseCore
import XCTest

/// 사진 보기의 얼굴 확대(Lightroom Classic Faces 패널·Narrative Close-ups처럼): 자를 영역, 같은 사진 얼굴끼리의 흐림 비교,
/// 실제 얼굴 표본에서의 눈 감음·흐림 판정.
final class FaceCloseupTests: XCTestCase {
    /// 얼굴 가운데의 정사각형(얼굴 긴 변의 1.6배)이고, 사진 가장자리에서는 사진 안으로 밀어 넣는다.
    func testCropIsASquareAroundTheFaceInsideThePhoto() {
        let size = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(FaceCloseupAnalyzer.cropRect(for: CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.15), imageSize: size),
                       CGRect(x: 740, y: 215, width: 320, height: 320))
        XCTAssertEqual(FaceCloseupAnalyzer.cropRect(for: CGRect(x: 0.94, y: 0.9, width: 0.05, height: 0.1), imageSize: size),
                       CGRect(x: 1840, y: 840, width: 160, height: 160), "오른쪽 아래 끝에서는 사진 안으로")
        XCTAssertEqual(FaceCloseupAnalyzer.cropRect(for: CGRect(x: 0.5, y: 0.5, width: 0.005, height: 0.01), imageSize: size).width,
                       48, "아주 작은 얼굴도 최소 48px은 자른다")
    }

    /// 흐림은 같은 사진에서 가장 선명한 얼굴과만 비교하고(0.2배 미만), 얼굴이 하나면 판단하지 않는다.
    func testSoftFacesAreJudgedOnlyAgainstOtherFaces() {
        func face(_ sharpness: Double?) -> FaceCloseup {
            FaceCloseup(bounds: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), eyesClosed: false, sharpness: sharpness)
        }
        // 서로 다른 두 사람의 선명한 얼굴도 조명·피부에 따라 3배까지 차이 난다(표본 1409 대 452).
        XCTAssertEqual(FaceCloseupAnalyzer.softFaceIndices([face(1409), face(452), face(70), face(nil)]), [2])
        XCTAssertEqual(FaceCloseupAnalyzer.softFaceIndices([face(70)]), [], "얼굴이 하나면 비교하지 않는다")
        XCTAssertEqual(FaceCloseupAnalyzer.softFaceIndices([face(900), face(nil)]), [], "너무 작은 얼굴은 비교에서 뺀다")
    }

    func testPlainPhotoHasNoFaces() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(FaceCloseupAnalyzer.analyze(try XCTUnwrap(context.makeImage())), [])
    }

    /// 실제 얼굴 표본(`LIGHTHOUSE_FACE_FIXTURES`): 두 사람 사진은 둘 다 눈 뜸·흐림 없음, 한 얼굴만 흐리게 하면 그 얼굴만 흐림,
    /// 두 눈을 피부색으로 덮은 사본은 눈 감음. 큰 얼굴부터 나온다.
    func testFixtureFacesEyesAndSoftness() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTHOUSE_FACE_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("LIGHTHOUSE_FACE_FIXTURES를 지정하면 로컬 얼굴 표본을 검사합니다.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let pipeline = ImagePipeline()
        let pair = try pipeline.thumbnail(for: directory.appendingPathComponent("two-people.jpg"), maxPixel: 2048)
        let faces = FaceCloseupAnalyzer.analyze(pair)
        XCTAssertEqual(faces.count, 2)
        XCTAssertEqual(faces.map(\.eyesClosed), [false, false])
        XCTAssertGreaterThanOrEqual(faces[0].bounds.width * faces[0].bounds.height, faces[1].bounds.width * faces[1].bounds.height)
        XCTAssertEqual(FaceCloseupAnalyzer.softFaceIndices(faces), [])

        let blurred = try blur(pair, around: faces[1].bounds)
        let blurredFaces = FaceCloseupAnalyzer.analyze(blurred)
        XCTAssertEqual(blurredFaces.count, 2)
        let softIndex = try XCTUnwrap(FaceCloseupAnalyzer.softFaceIndices(blurredFaces).first, "흐리게 한 얼굴을 찾아야 한다")
        XCTAssertEqual(blurredFaces[softIndex].bounds.midX, faces[1].bounds.midX, accuracy: 0.05)

        let single = try pipeline.thumbnail(for: directory.appendingPathComponent("person-a-1.jpg"), maxPixel: 2048)
        XCTAssertEqual(FaceCloseupAnalyzer.analyze(single).map(\.eyesClosed), [false])
        XCTAssertEqual(FaceCloseupAnalyzer.analyze(try coverEyes(single)).map(\.eyesClosed), [true])
    }

    /// 0…1(왼쪽 위 원점) 얼굴 영역 둘레를 가우스 흐림(σ 3)으로 바꾼 사본.
    private func blur(_ image: CGImage, around bounds: CGRect) throws -> CGImage {
        let source = CIImage(cgImage: image)
        let width = Double(image.width), height = Double(image.height)
        let area = CGRect(x: bounds.minX * width, y: (1 - bounds.maxY) * height, width: bounds.width * width,
                          height: bounds.height * height).insetBy(dx: -bounds.width * width * 0.3, dy: -bounds.height * height * 0.3)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: area).composited(over: source)
        return try XCTUnwrap(CIContext().createCGImage(blurred, from: source.extent))
    }

    /// Core Image가 찾은 두 눈 자리를 볼 쪽 피부색 타원과 눈꺼풀 선으로 덮은 사본(감은 눈 흉내).
    private func coverEyes(_ image: CGImage) throws -> CGImage {
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeFace, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let face = try XCTUnwrap(detector.features(in: CIImage(cgImage: image)).first as? CIFaceFeature)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let gap = abs(face.rightEyePosition.x - face.leftEyePosition.x)
        let cheek = CGPoint(x: face.leftEyePosition.x, y: face.leftEyePosition.y - face.bounds.height * 0.18)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (image.height - 1 - Int(cheek.y)) * image.width * 4 + Int(cheek.x) * 4
        context.setFillColor(CGColor(red: Double(pixels[offset]) / 255, green: Double(pixels[offset + 1]) / 255,
                                     blue: Double(pixels[offset + 2]) / 255, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0.15, alpha: 0.9))
        context.setLineWidth(max(2, gap * 0.025))
        for eye in [face.leftEyePosition, face.rightEyePosition] {
            context.fillEllipse(in: CGRect(x: eye.x - gap * 0.32, y: eye.y - gap * 0.14, width: gap * 0.64, height: gap * 0.28))
            context.move(to: CGPoint(x: eye.x - gap * 0.25, y: eye.y))
            context.addQuadCurve(to: CGPoint(x: eye.x + gap * 0.25, y: eye.y), control: CGPoint(x: eye.x, y: eye.y - gap * 0.06))
            context.strokePath()
        }
        return try XCTUnwrap(context.makeImage())
    }
}
