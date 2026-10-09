import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LighthouseCore

final class CameraProfileTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: DCP 읽기

    func testParsesLittleAndBigEndianProfiles() throws {
        for (littleEndian, magic) in [(true, UInt16(0x4352)), (false, UInt16(42))] {
            let profile = try DNGProfile.parse(makeDCP(standardTags(name: "Camera Vivid", toneCurve: true),
                                                       littleEndian: littleEndian, magic: magic))
            XCTAssertEqual(profile.name, "Camera Vivid")
            XCTAssertEqual(profile.uniqueCameraModel, "Panasonic DC-S9")
            XCTAssertEqual(profile.hueSatMap1?.hueDivisions, 6)
            XCTAssertEqual(profile.hueSatMap2?.saturationDivisions, 2)
            XCTAssertEqual(profile.lookTable?.valueDivisions, 2)
            XCTAssertEqual(profile.lookTable?.isSRGBEncoded, true)
            XCTAssertEqual(profile.toneCurve?.count, 3)
            XCTAssertEqual(profile.baselineExposureOffset, 0.25, accuracy: 1e-6)
            XCTAssertEqual(profile.forwardMatrix1, Matrix3(values: Self.forward))
        }
    }

    func testRejectsMalformedProfiles() throws {
        XCTAssertThrowsError(try DNGProfile.parse(Data("not a profile".utf8))) {
            XCTAssertEqual($0 as? DNGProfileError, .notProfile)
        }
        let valid = makeDCP(standardTags(name: "Adobe Standard"))
        XCTAssertThrowsError(try DNGProfile.parse(valid.prefix(valid.count - 40))) {
            XCTAssertEqual($0 as? DNGProfileError, .truncated)
        }
        var tags = standardTags(name: "Adobe Standard")
        tags.removeAll { $0.0 == 50936 }
        XCTAssertThrowsError(try DNGProfile.parse(makeDCP(tags))) { XCTAssertEqual($0 as? DNGProfileError, .missingName) }

        tags = standardTags(name: "Adobe Standard")
        tags.removeAll { $0.0 == 50938 }
        tags.append((50938, .float([0, 1, 1])))
        XCTAssertThrowsError(try DNGProfile.parse(makeDCP(tags))) {
            XCTAssertEqual($0 as? DNGProfileError, .invalidTag("HueSatMap"))
        }
        tags = standardTags(name: "Camera Flat")
        tags.append((50940, .float([0, 0, 0.6, 0.5, 0.4, 0.7, 1, 1])))
        XCTAssertThrowsError(try DNGProfile.parse(makeDCP(tags))) {
            XCTAssertEqual($0 as? DNGProfileError, .invalidTag("ProfileToneCurve"))
        }
    }

    // MARK: 색 변환

    func testIdentityProfileKeepsColorsIncludingValuesAboveOne() throws {
        let profile = try DNGProfile.parse(makeDCP(standardTags(name: "Adobe Standard")))
        let transform = DNGProfileTransform(profile: profile, reference: profile, temperature: 5000)
        for rgb in [SIMD3(0.2, 0.4, 0.6), SIMD3(0.9, 0.1, 0.05), SIMD3(0.5, 0.5, 0.5), SIMD3(2.5, 1.2, 0.8)] {
            let output = transform.apply(rgb)
            XCTAssertLessThan(maxDifference(output, rgb), 1e-6, "\(rgb) → \(output)")
        }
    }

    func testForwardMatrixDifferenceUsesReferenceProfile() throws {
        var tags = standardTags(name: "Camera Saturated")
        tags.removeAll { $0.0 == 50964 || $0.0 == 50965 }
        // ProPhoto 행렬 그대로면 카메라 RGB를 ProPhoto로 본다. 기준 행렬과 다르므로 색이 바뀐다.
        let proPhoto = DNGProfileTransform.proPhotoToXYZ.values
        tags += [(50964, .srational(proPhoto)), (50965, .srational(proPhoto))]
        let profile = try DNGProfile.parse(makeDCP(tags))
        let reference = try DNGProfile.parse(makeDCP(standardTags(name: "Adobe Standard")))
        // 이 프로필에는 노출 오프셋 +0.25 EV가 있다.
        let exposure = pow(2, 0.25)
        let transform = DNGProfileTransform(profile: profile, reference: reference, temperature: 5000)
        let gray = transform.apply(SIMD3(repeating: 0.3))
        XCTAssertLessThan(maxDifference(gray, SIMD3(repeating: 0.3 * exposure)), 2e-3,
                          "두 행렬 모두 흰색을 D50 근처로 보내므로 회색은 거의 그대로")
        let color = transform.apply(SIMD3(0.6, 0.3, 0.1))
        XCTAssertGreaterThan(maxDifference(color, SIMD3(0.6, 0.3, 0.1) * exposure), 0.005)
    }

    func testHueSatMapShiftsHueScalesSaturationAndInterpolatesValue() {
        let shift = DNGProfile.HueSatTable(hueDivisions: 6, saturationDivisions: 2, valueDivisions: 1,
                                           deltas: Array(repeating: [60, 1, 1], count: 12).flatMap { $0 },
                                           isSRGBEncoded: false)
        let yellow = DNGProfileTransform.applying(shift, to: SIMD3(1, 0, 0))
        XCTAssertLessThan(maxDifference(yellow, SIMD3(1, 1, 0)), 1e-9, "+60°는 빨강을 노랑으로 돌린다")

        let desaturate = DNGProfile.HueSatTable(hueDivisions: 1, saturationDivisions: 2, valueDivisions: 1,
                                                deltas: [0, 0.5, 1, 0, 0.5, 1], isSRGBEncoded: false)
        let half = DNGProfileTransform.applying(desaturate, to: SIMD3(0.8, 0.4, 0.4))
        XCTAssertLessThan(maxDifference(half, SIMD3(0.8, 0.6, 0.6)), 1e-9, "채도 배율 0.5")

        // 명도 축 두 칸(sRGB 인코딩): 어두운 끝 배율 1, 밝은 끝 0.5. 인코딩 0.5에서 0.75배가 된다.
        let value = DNGProfile.HueSatTable(hueDivisions: 1, saturationDivisions: 2, valueDivisions: 2,
                                           deltas: [0, 1, 1, 0, 1, 1, 0, 1, 0.5, 0, 1, 0.5], isSRGBEncoded: true)
        let gray = DNGProfileTransform.srgbDecode(0.5)
        let darker = DNGProfileTransform.applying(value, to: SIMD3(repeating: gray))
        XCTAssertEqual(darker.x, DNGProfileTransform.srgbDecode(0.375), accuracy: 1e-9)
        let bright = DNGProfileTransform.applying(value, to: SIMD3(repeating: 3))
        XCTAssertEqual(bright.x, 3 * DNGProfileTransform.srgbDecode(0.5), accuracy: 1e-9, "1 위의 값은 같은 배율로 남는다")
    }

    func testRGBToneCurvesExtremesAndKeepsMiddleRatio() {
        let curve = (0...10).map { SIMD2(Double($0) / 10, (Double($0) / 10).squareRoot()) }
        let toned = DNGProfileTransform.applyingTone(curve, to: SIMD3(0.64, 0.36, 0.16))
        let high = DNGProfileTransform.interpolate(curve, 0.64), low = DNGProfileTransform.interpolate(curve, 0.16)
        XCTAssertEqual(toned.x, high, accuracy: 1e-12)
        XCTAssertEqual(toned.z, low, accuracy: 1e-12)
        XCTAssertEqual(toned.y, low + (high - low) * (0.36 - 0.16) / (0.64 - 0.16), accuracy: 1e-12)
        XCTAssertEqual(DNGProfileTransform.applyingTone(curve, to: SIMD3(repeating: 0.25)).x,
                       DNGProfileTransform.interpolate(curve, 0.25), accuracy: 1e-12)
    }

    func testIlluminantWeightUsesInverseTemperature() throws {
        let profile = try DNGProfile.parse(makeDCP(standardTags(name: "Adobe Standard")))
        XCTAssertEqual(profile.illuminantWeight(temperature: 2000), 1)
        XCTAssertEqual(profile.illuminantWeight(temperature: 9000), 0)
        XCTAssertEqual(profile.illuminantWeight(temperature: 4000),
                       (1 / 4000 - 1 / 6504) / (1 / 2856 - 1 / 6504), accuracy: 1e-12)
    }

    // MARK: 찾기

    func testCameraNameMatching() {
        XCTAssertTrue(CameraProfileLibrary.matches(uniqueCameraModel: "Panasonic DC-S9", camera: "PANASONIC DC-S9"))
        XCTAssertTrue(CameraProfileLibrary.matches(uniqueCameraModel: "Nikon Z 6", camera: "NIKON CORPORATION NIKON Z 6"))
        XCTAssertFalse(CameraProfileLibrary.matches(uniqueCameraModel: "Panasonic DC-S9", camera: "Panasonic DC-S5"))
        XCTAssertFalse(CameraProfileLibrary.matches(uniqueCameraModel: "Canon EOS R5", camera: "Canon EOS R5 C"))
        XCTAssertFalse(CameraProfileLibrary.matches(uniqueCameraModel: "Panasonic DC-S9", camera: ""))
    }

    func testLibraryFindsMatchingProfilesWithUserProfilesFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let adobe = root.appendingPathComponent("Adobe", isDirectory: true)
        let user = root.appendingPathComponent("User", isDirectory: true)
        func write(_ data: Data, _ path: String, in directory: URL) throws {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write(makeDCP(standardTags(name: "Adobe Standard")), "Adobe Standard/Panasonic DC-S9 Adobe Standard.dcp", in: adobe)
        try write(makeDCP(standardTags(name: "Camera Vivid")), "Camera/Panasonic DC-S9/Panasonic DC-S9 Camera Vivid.dcp",
                  in: adobe)
        try write(makeDCP(standardTags(name: "Adobe Standard", camera: "Canon EOS R5")),
                  "Adobe Standard/Canon EOS R5 Adobe Standard.dcp", in: adobe)
        try write(makeDCP(standardTags(name: "Camera Vivid")), "My Vivid.dcp", in: user)
        try write(Data("broken".utf8), "broken.dcp", in: user)

        let library = CameraProfileLibrary(adobeDirectory: adobe, userDirectory: user)
        let profiles = library.profiles(forCamera: "Panasonic DC-S9")
        XCTAssertEqual(profiles.map(\.name), ["Adobe Standard", "Camera Vivid"])
        XCTAssertEqual(profiles.first { $0.name == "Camera Vivid" }?.isUserProfile, true, "사용자 폴더가 앞선다")
        XCTAssertEqual(library.profiles(forCamera: "Canon EOS R5").map(\.name), ["Adobe Standard"])
        XCTAssertEqual(library.profiles(forCamera: nil), [])
        XCTAssertEqual(library.identity(name: "Camera Missing", camera: "Panasonic DC-S9"), "missing")
    }

    // MARK: 캘리브레이션

    func testCalibrationMatrixKeepsWhiteAndMovesPrimaries() {
        let neutral = CalibrationProcessor.matrix(.neutral).values
        XCTAssertLessThan(zip(neutral, Matrix3.identity.values).map { abs($0 - $1) }.max()!, 1e-12)
        let settings = CalibrationSettings(redHue: 0.7, redSaturation: -0.4, greenHue: -0.3, blueSaturation: 0.8)
        let matrix = CalibrationProcessor.matrix(settings)
        XCTAssertLessThan(maxDifference(matrix.apply(SIMD3(repeating: 1)), SIMD3(repeating: 1)), 1e-12, "흰색은 그대로")
        XCTAssertLessThan(maxDifference(matrix.apply(SIMD3(repeating: 0.2)), SIMD3(repeating: 0.2)), 1e-12)

        let warmer = CalibrationProcessor.matrix(CalibrationSettings(redHue: 1)).apply(SIMD3(1, 0, 0))
        XCTAssertGreaterThan(warmer.y - warmer.z, 0.1, "빨강 색조 +는 노랑 쪽(주황)으로 간다")
        let richer = CalibrationProcessor.matrix(CalibrationSettings(blueSaturation: 1)).apply(SIMD3(0, 0, 1))
        let plain = SIMD3<Double>(0, 0, 1)
        XCTAssertGreaterThan(richer.z - max(richer.x, richer.y), plain.z - max(plain.x, plain.y), "파랑 채도 +는 더 진하다")
        let duller = CalibrationProcessor.matrix(CalibrationSettings(greenSaturation: -1)).apply(SIMD3(0, 1, 0))
        XCTAssertLessThan(duller.y - max(duller.x, duller.z), 1, "초록 채도 -는 옅다")
    }

    func testCalibrationModelDefaultsAndRejectsInvalidValues() throws {
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(EditSettings())) as? [String: Any])
        XCTAssertNil(plain["calibration"])
        XCTAssertNil(plain["cameraProfile"])
        let edits = EditSettings(cameraProfile: "Camera Vivid", calibration: CalibrationSettings(shadowTint: 0.2, blueHue: -0.5))
        XCTAssertEqual(try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(edits)), edits)
        XCTAssertEqual(edits.changeSummary(from: EditSettings(cameraProfile: "Camera Vivid")), "캘리브레이션")
        XCTAssertEqual(EditSettings(cameraProfile: "Adobe Standard").changeSummary(from: EditSettings()), "카메라 프로필")
        XCTAssertEqual(EditSettings().merging(from: edits, components: .global).calibration, edits.calibration)
        XCTAssertEqual(EditSettings().merging(from: edits, components: .global).cameraProfile, "Camera Vivid")

        for (key, value) in [("calibration", ["redHue": 1.5] as Any), ("calibration", ["shadowTint": "x"]),
                             ("cameraProfile", ""), ("cameraProfile", String(repeating: "a", count: 129))] {
            var object = plain
            object[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(EditSettings.self,
                                                          from: JSONSerialization.data(withJSONObject: object)), key)
        }
        var partial = plain
        partial["calibration"] = ["greenHue": 0.25]
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: partial))
        XCTAssertEqual(decoded.calibration, CalibrationSettings(greenHue: 0.25))
    }

    func testShadowTintAndPrimariesRenderWithPreviewMatchingExport() throws {
        let url = try temporaryPNG(width: 64, height: 16) { x, _ in
            x < 32 ? SIMD3(repeating: 0.25) : SIMD3(repeating: 1)
        }
        let neutral = try rgba8(ImagePipeline().render(url: url, edits: EditSettings(), maxPixel: nil))
        let edits = EditSettings(calibration: CalibrationSettings(shadowTint: 1))
        let tinted = try rgba8(ImagePipeline().render(url: url, edits: edits, maxPixel: nil))
        let dark = 8 * 64 * 4 + 8 * 4, white = 8 * 64 * 4 + 48 * 4
        XCTAssertGreaterThan(Int(tinted[dark]), Int(tinted[dark + 1]) + 3, "그림자가 마젠타 쪽으로 간다")
        XCTAssertGreaterThan(Int(tinted[dark + 2]), Int(tinted[dark + 1]) + 3)
        XCTAssertEqual(Array(tinted[white..<white + 3]), Array(neutral[white..<white + 3]), "흰색은 그대로")
        let green = try rgba8(ImagePipeline().render(
            url: url, edits: EditSettings(calibration: CalibrationSettings(shadowTint: -1)), maxPixel: nil))
        XCTAssertGreaterThan(Int(green[dark + 1]), Int(green[dark]) + 3, "음수는 초록")

        let both = EditSettings(calibration: CalibrationSettings(shadowTint: 0.5, redHue: 0.4, blueSaturation: 0.6))
        let preview = try ImagePipeline(cachesDevelopment: true).renderPreview(url: url, edits: both, maxPixel: nil,
                                                                               allowApproximation: true)
        XCTAssertEqual(try rgba8(preview.image), try rgba8(ImagePipeline().render(url: url, edits: both, maxPixel: nil)))
    }

    // MARK: 프리셋 가져오기

    func testImportsCameraProfileAndCalibration() throws {
        let preset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Vivid Calib" crs:CameraProfile="Camera Vivid" crs:ShadowTint="-10"
          crs:RedHue="20" crs:RedSaturation="-30" crs:GreenHue="5" crs:GreenSaturation="0"
          crs:BlueHue="-40" crs:BlueSaturation="100"/>
        """), fileName: "vivid.xmp")
        let payload = try XCTUnwrap(preset.lightroom)
        XCTAssertEqual(payload.cameraProfile, "Camera Vivid")
        XCTAssertTrue(payload.warnings.contains("카메라 프로필은 이 Mac에 설치된 DCP로 근사하며 Adobe 결과와 다를 수 있습니다."))
        XCTAssertTrue(payload.warnings.contains("캘리브레이션은 Lighthouse 수식으로 근사하며 Adobe 결과와 다를 수 있습니다."))
        XCTAssertFalse(payload.warnings.contains { $0.hasPrefix("지원하지 않아 제외") }, "\(payload.warnings)")
        let applied = preset.applied(to: EditSettings(exposure: 0.3, colorProfile: .monochrome), isRAW: true)
        XCTAssertEqual(applied.cameraProfile, "Camera Vivid")
        XCTAssertEqual(applied.colorProfile, .color)
        XCTAssertEqual(applied.exposure, 0.3)
        XCTAssertEqual(applied.calibration, CalibrationSettings(shadowTint: -0.1, redHue: 0.2, redSaturation: -0.3,
                                                                greenHue: 0.05, blueHue: -0.4, blueSaturation: 1))

        let standard = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Std" crs:CameraProfile="Adobe Standard"/>
        """), fileName: "std.xmp")
        XCTAssertEqual(standard.applied(to: EditSettings(), isRAW: true).cameraProfile, "Adobe Standard")

        let look = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Look" crs:CameraProfile="Adobe Color" crs:Dehaze="5"/>
        """), fileName: "look.xmp")
        XCTAssertNil(try XCTUnwrap(look.lightroom).cameraProfile)
        XCTAssertTrue(try XCTUnwrap(look.lightroom).warnings.contains("지원하지 않아 제외: CameraProfile (Adobe Color)"))

        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:Name="Bad" crs:RedHue="101"/>
        """), fileName: "bad.xmp")) { XCTAssertEqual($0 as? LightroomPresetImportError, .invalidValue("RedHue")) }
    }

    // MARK: 실제 S9와 설치된 DCP

    func testRealS9RendersInstalledProfilesOrFallsBack() throws {
        guard let raw = Self.rawSample else { throw XCTSkip("RAW 표본이 없습니다.") }
        let pipeline = ImagePipeline()
        let names = pipeline.cameraProfileNames(for: raw)
        guard names.contains("Adobe Standard"), names.contains("Camera Monochrome") else {
            throw XCTSkip("이 Mac에 S9용 Adobe DCP가 없습니다.")
        }
        XCTAssertTrue(pipeline.cameraProfileIsAvailable("Camera Vivid", for: raw))
        XCTAssertFalse(pipeline.cameraProfileIsAvailable("Camera Nope", for: raw))
        let plain = try rgba8(pipeline.render(url: raw, edits: EditSettings(), maxPixel: 300))
        XCTAssertEqual(try rgba8(pipeline.render(url: raw, edits: EditSettings(cameraProfile: "Camera Nope"), maxPixel: 300)),
                       plain, "찾지 못한 프로필은 macOS 기본으로 그린다")
        XCTAssertNotEqual(try rgba8(pipeline.render(url: raw, edits: EditSettings(cameraProfile: "Adobe Standard"),
                                                    maxPixel: 300)), plain)
        let mono = try rgba8(pipeline.render(url: raw, edits: EditSettings(cameraProfile: "Camera Monochrome"), maxPixel: 300))
        var chroma = 0
        for index in stride(from: 0, to: mono.count, by: 4) {
            chroma = max(chroma, Int(max(mono[index], mono[index + 1], mono[index + 2]))
                         - Int(min(mono[index], mono[index + 1], mono[index + 2])))
        }
        XCTAssertLessThanOrEqual(chroma, 2, "Camera Monochrome은 무채색이다")
        XCTAssertEqual(pipeline.cameraProfileNames(for: URL(fileURLWithPath: "/tmp/photo.jpg")), [])
    }

    // MARK: 도우미

    private static let forward: [Double] = [0.4409, 0.4176, 0.1058, 0.2049, 0.7639, 0.0311, 0.0759, 0.0003, 0.7489]

    private static var rawSample: URL? {
        if let path = ProcessInfo.processInfo.environment["LIGHTHOUSE_SAMPLE_RW2"], !path.isEmpty {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(".artifacts/samples/LUMIX-S9.RW2")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private enum TagValue {
        case ascii(String), short([UInt16]), long([UInt32]), srational([Double]), float([Float])
    }

    /// 단위 HueSatMap(6×2×1, 두 표준광), sRGB 인코딩 LookTable(1×2×2), 노출 오프셋 0.25를 가진 프로필.
    private func standardTags(name: String, camera: String = "Panasonic DC-S9",
                              toneCurve: Bool = false) -> [(UInt16, TagValue)] {
        let identity: [Float] = Array(repeating: [Float(0), Float(1), Float(1)], count: 12).flatMap { $0 }
        var tags: [(UInt16, TagValue)] = [
            (50708, .ascii(camera)), (50778, .short([17])), (50779, .short([21])), (50936, .ascii(name)),
            (50937, .long([6, 2, 1])), (50938, .float(identity)), (50939, .float(identity)),
            (50964, .srational(Self.forward)), (50965, .srational(Self.forward)),
        ]
        if name != "Adobe Standard" {
            tags += [(50981, .long([1, 2, 2])), (50982, .float(Array(repeating: [Float(0), Float(1), Float(1)], count: 4).flatMap { $0 })),
                     (51108, .long([1])), (51109, .srational([0.25]))]
        }
        if toneCurve { tags.append((50940, .float([0, 0, 0.5, 0.6, 1, 1]))) }
        return tags
    }

    private func makeDCP(_ tags: [(UInt16, TagValue)], littleEndian: Bool = true, magic: UInt16 = 0x4352) -> Data {
        func u16(_ v: UInt16) -> [UInt8] { littleEndian ? [UInt8(v & 0xff), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xff)] }
        func u32(_ v: UInt32) -> [UInt8] {
            let bytes = (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) }
            return littleEndian ? bytes : bytes.reversed()
        }
        let sorted = tags.sorted { $0.0 < $1.0 }
        var header: [UInt8] = (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(magic) + u32(8)
        let dataStart = 8 + 2 + 12 * sorted.count + 4
        var ifd = u16(UInt16(sorted.count))
        var payloadArea: [UInt8] = []
        for (tag, value) in sorted {
            let (type, count, payload): (UInt16, Int, [UInt8]) = switch value {
            case .ascii(let text): (2, text.utf8.count + 1, Array(text.utf8) + [0])
            case .short(let values): (3, values.count, values.flatMap(u16))
            case .long(let values): (4, values.count, values.flatMap(u32))
            case .srational(let values):
                (10, values.count, values.flatMap { u32(UInt32(bitPattern: Int32(($0 * 100_000).rounded()))) + u32(100_000) })
            case .float(let values): (11, values.count, values.flatMap { u32($0.bitPattern) })
            }
            ifd += u16(tag) + u16(type) + u32(UInt32(count))
            if payload.count <= 4 {
                ifd += payload + [UInt8](repeating: 0, count: 4 - payload.count)
            } else {
                ifd += u32(UInt32(dataStart + payloadArea.count))
                payloadArea += payload
                if payloadArea.count % 2 == 1 { payloadArea.append(0) }
            }
        }
        ifd += u32(0)
        header += ifd
        return Data(header + payloadArea)
    }

    private func maxDifference(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        [abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)].max()!
    }

    private func rgba8(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    private func temporaryPNG(width: Int, height: Int, color: (Int, Int) -> SIMD3<Double>) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = color(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((rgb.x * 255).rounded())
                bytes[offset + 1] = UInt8((rgb.y * 255).rounded())
                bytes[offset + 2] = UInt8((rgb.z * 255).rounded())
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func xmp(_ descriptions: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
            \(descriptions)
          </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }
}
