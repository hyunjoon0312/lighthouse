import Foundation
import XCTest
@testable import LighthouseCore

final class LightroomPresetTests: XCTestCase {
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

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testXMPParsesNamespaceAttributesElementsNameAndPrefersModernCurve() throws {
        let preset = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description xmlns:cam="http://ns.adobe.com/camera-raw-settings/1.0/"
                         crs:PresetType="Normal" cam:Exposure2012="5" crs:Exposure="-2">
          <crs:Name><rdf:Alt><rdf:li xml:lang="fr">Autre</rdf:li><rdf:li xml:lang="x-default">Bright</rdf:li></rdf:Alt></crs:Name>
          <crs:Saturation>20</crs:Saturation>
          <crs:ToneCurve><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 200</rdf:li></rdf:Seq></crs:ToneCurve>
          <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
          <crs:Look><rdf:RDF><rdf:Description crs:Exposure2012="-4"/></rdf:RDF></crs:Look>
        </rdf:Description>
        """), fileName: "fallback.xmp")
        XCTAssertEqual(preset.name, "Bright")
        let payload = try XCTUnwrap(preset.lightroom)
        XCTAssertEqual(payload.scalars["Exposure2012"], 5)
        XCTAssertNil(payload.scalars["Exposure"])
        XCTAssertEqual(payload.scalars["Saturation"], 20)
        XCTAssertEqual(payload.curves["master"], ToneCurves.identityPoints)
        XCTAssertTrue(payload.warnings.contains(where: { $0.contains("Look") }))
        XCTAssertTrue(payload.warnings.contains(where: { $0.contains("-4…4") }))
    }

    func testXMPRejectsConflictsUnsafeXMLAndWrongType() throws {
        let conflict = xmp("""
        <rdf:Description crs:Exposure2012="1"/>
        <rdf:Description crs:Exposure2012="2"/>
        """)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: conflict, fileName: "x.xmp")) {
            XCTAssertEqual($0 as? LightroomPresetImportError, .conflictingValue("Exposure2012"))
        }
        let dtd = Data(#"<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e "1">]><x/>"#.utf8)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: dtd, fileName: "x.xmp")) {
            XCTAssertEqual($0 as? LightroomPresetImportError, .unsafeXML)
        }
        let profile = xmp("<rdf:Description crs:PresetType=\"Profile\" crs:Exposure2012=\"1\"/>")
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: profile, fileName: "x.xmp"))
        let utf16 = "<rdf:RDF/>".data(using: .utf16)!
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: utf16, fileName: "x.xmp")) {
            XCTAssertEqual($0 as? LightroomPresetImportError, .invalidEncoding)
        }
        let structuredScalar = xmp("""
        <rdf:Description><crs:Exposure2012><rdf:Seq><rdf:li>1</rdf:li></rdf:Seq></crs:Exposure2012></rdf:Description>
        """)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: structuredScalar, fileName: "x.xmp")) {
            XCTAssertEqual($0 as? LightroomPresetImportError, .invalidValue("Exposure2012"))
        }
    }

    func testExtendedToneDirectionsAndUnsupportedOnlyPreset() throws {
        let data = xmp("""
        <rdf:Description crs:Highlights2012="20" crs:Shadows2012="-20"
                         crs:Whites2012="35" crs:Blacks2012="-40" crs:GrainFrequency="75"/>
        """)
        let payload = try XCTUnwrap(LightroomPresetImporter.parse(data: data, fileName: "tone.xmp").lightroom)
        let applied = payload.applying(to: .neutral, isRAW: false)
        XCTAssertEqual(applied.highlights, 1.2)
        XCTAssertEqual(applied.shadows, -0.2)
        XCTAssertEqual(applied.whites, 0.35)
        XCTAssertEqual(applied.blacks, -0.4)
        XCTAssertEqual(applied.grain.roughness, 0.75)

        let unsupported = xmp("<rdf:Description crs:LensProfileEnable=\"1\"/>")
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: unsupported, fileName: "empty.xmp")) {
            XCTAssertEqual($0 as? LightroomPresetImportError, .emptyPreset)
        }
    }

    func testLRTemplateParsesLiteralAndRejectsCodeOrNonDevelopType() throws {
        let source = Data("""
        s = {
          title = "Warm Film",
          type = "Develop",
          value = { settings = {
            Exposure2012 = 1.25,
            HueAdjustmentRed = 10,
            ToneCurvePV2012 = { 0, 0, 255, 255 },
            MaskGroupBasedCorrections = { { Exposure2012 = 4 } },
          } },
        }
        """.utf8)
        let preset = try LightroomPresetImporter.parse(data: source, fileName: "warm.lrtemplate")
        XCTAssertEqual(preset.name, "Warm Film")
        XCTAssertEqual(preset.lightroom?.scalars["Exposure2012"], 1.25)
        XCTAssertEqual(preset.lightroom?.curves["master"], ToneCurves.identityPoints)
        XCTAssertTrue(preset.lightroom?.warnings.contains(where: { $0.contains("Mask") }) == true)

        let code = Data("s = function() return {} end".utf8)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: code, fileName: "bad.lrtemplate"))
        let printCall = Data("s = { value = { settings = { Exposure2012 = os.execute('x') } } }".utf8)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: printCall, fileName: "bad.lrtemplate"))
        let wrongType = Data("s = { type = 'Export', value = { settings = { Exposure2012 = 1 } } }".utf8)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: wrongType, fileName: "bad.lrtemplate"))
    }

    func testLRTemplateWarnsUnsupportedNumericAndMalformedModernBlocksLegacyCurve() throws {
        let source = Data("""
        s = { type = "Develop", value = { settings = {
          Exposure2012 = 1,
          Whites2012 = 20,
          ToneCurvePV2012 = { 0, 0, 255 },
          ToneCurve = { 0, 0, 255, 255 },
        } } }
        """.utf8)
        let preset = try LightroomPresetImporter.parse(data: source, fileName: "priority.lrtemplate")
        let payload = try XCTUnwrap(preset.lightroom)
        XCTAssertNil(payload.curves["master"])
        XCTAssertEqual(payload.scalars["Whites2012"], 20)
        XCTAssertTrue(payload.warnings.contains(where: { $0.contains("ToneCurvePV2012") }))
    }

    func testDefaultProfilesAndGrayscaleOverride() throws {
        let known = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:CameraProfile="Default Color" crs:ConvertToGrayscale="True"/>
        """), fileName: "profile.xmp")
        let payload = try XCTUnwrap(known.lightroom)
        XCTAssertEqual(payload.colorProfile, .monochrome)
        XCTAssertTrue(payload.scalars.isEmpty)
        XCTAssertTrue(payload.warnings.contains(where: { $0.contains("Lighthouse 기본 색상") }))
        XCTAssertTrue(payload.warnings.contains(where: { $0.contains("기본 흑백을 우선 적용") }))

        let unknown = try LightroomPresetImporter.parse(data: xmp("""
        <rdf:Description crs:CameraProfile="Camera Standard" crs:ConvertToGrayscale="False"/>
        """), fileName: "unknown.xmp")
        XCTAssertEqual(unknown.lightroom?.colorProfile, .color)
        XCTAssertTrue(unknown.lightroom?.warnings.contains(where: { $0.contains("Camera Standard") }) == true)
        XCTAssertTrue(unknown.lightroom?.warnings.contains(where: { $0.contains("기본 색상을 우선 적용") }) == true)

        let template = Data("""
        s = { type = "Develop", value = { settings = {
          CameraProfile = "Default Monochrome", ConvertToGrayscale = false,
        } } }
        """.utf8)
        XCTAssertEqual(try LightroomPresetImporter.parse(data: template, fileName: "p.lrtemplate")
            .lightroom?.colorProfile, .color)

        let invalid = Data("s = { type = 'Develop', value = { settings = { ConvertToGrayscale = 1 } } }".utf8)
        XCTAssertThrowsError(try LightroomPresetImporter.parse(data: invalid, fileName: "bad.lrtemplate"))
    }

    func testPartialApplicationPreservesUnspecifiedFieldsAndExplicitZero() throws {
        let payload = LightroomPresetPayload(
            format: "xmp",
            scalars: ["Exposure2012": 0, "HueAdjustmentRed": 0, "SaturationAdjustmentRed": -20,
                      "GrainSize": 20],
            curves: ["red": ToneCurves.identityPoints],
            warnings: ["Adobe 현상 엔진과 결과가 다를 수 있습니다."]
        )
        let preset = EditPreset(name: "Partial", lightroom: payload)
        var target = EditSettings(exposure: 2, contrast: 1.4, saturation: 1.3, temperatureShift: 12,
                                  highlights: 0.4, shadows: 0.7, sharpness: 0.8,
                                  colorRanges: [ColorRangeAdjustment(band: .red, hue: 12, saturation: 0.5, lightness: 0.4)],
                                  grain: GrainSettings(amount: 0.6, size: 1, seed: 42), hdrAmount: 1)
        target.cropRect = NormalizedCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        target.lut = LUTAdjustment(id: String(repeating: "a", count: 64), name: "Keep")
        target.localAdjustments = [LocalAdjustment(exposure: 1)]
        let applied = preset.applied(to: target, isRAW: false)
        XCTAssertEqual(applied.exposure, 0)
        XCTAssertEqual(applied.contrast, target.contrast)
        XCTAssertEqual(applied.temperatureShift, target.temperatureShift)
        XCTAssertEqual(applied.highlights, target.highlights)
        XCTAssertEqual(applied.hdrAmount, target.hdrAmount)
        XCTAssertEqual(applied.cropRect, target.cropRect)
        XCTAssertEqual(applied.lut, target.lut)
        XCTAssertEqual(applied.localAdjustments, target.localAdjustments)
        XCTAssertEqual(applied.colorRanges[0].hue, 0)
        XCTAssertEqual(applied.colorRanges[0].saturation, -0.2)
        XCTAssertEqual(applied.colorRanges[0].lightness, 0.4)
        XCTAssertEqual(applied.grain.amount, 0.6)
        XCTAssertEqual(applied.grain.size, 2)
        XCTAssertEqual(applied.grain.seed, 42)
        XCTAssertEqual(applied.grain.roughness, target.grain.roughness)
    }

    func testStoreRoundTripLegacyCompatibilityAndExplicitNullRejection() throws {
        let url = try temporaryFile(named: "presets.json", data: Data())
        let store = EditPresetStore(url: url)
        let preset = EditPreset(name: "Imported", lightroom: LightroomPresetPayload(
            format: "xmp", scalars: ["Exposure2012": 1], curves: [:], warnings: ["engine"]
        ))
        try store.save([preset])
        XCTAssertEqual(try store.load(), [preset])

        let legacy = EditPreset(name: "Legacy", source: EditSettings(exposure: 0.4), components: .global)
        let encodedLegacy = try JSONEncoder().encode(legacy)
        let legacyObject = try JSONSerialization.jsonObject(with: encodedLegacy)
        let legacyData = try JSONSerialization.data(withJSONObject: ["version": 1, "presets": [legacyObject]])
        try legacyData.write(to: url)
        XCTAssertNil(try store.load().first?.lightroom)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        var presets = try XCTUnwrap(object["presets"] as? [[String: Any]])
        presets[0]["lightroom"] = NSNull()
        object["presets"] = presets
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)

        let profileOnly = LightroomPresetPayload(format: "xmp", scalars: [:], curves: [:], warnings: [],
                                                 colorProfile: .monochrome)
        XCTAssertNoThrow(try profileOnly.validate())
        var profileObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(profileOnly)
        ) as? [String: Any])
        profileObject["colorProfile"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(
            LightroomPresetPayload.self,
            from: JSONSerialization.data(withJSONObject: profileObject)
        ))
    }

    func testLoadRejectsOversizeBeforeParsing() throws {
        let data = Data(repeating: 0x20, count: LightroomPresetImporter.maximumFileSize + 1)
        let url = try temporaryFile(named: "large.xmp", data: data)
        XCTAssertThrowsError(try LightroomPresetImporter.load(url: url)) {
            XCTAssertEqual($0 as? LightroomPresetImportError, .fileTooLarge)
        }
    }
}
