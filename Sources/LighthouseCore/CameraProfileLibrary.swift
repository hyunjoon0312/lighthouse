import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// 이 Mac에 설치된 DCP 하나.
public struct CameraProfileInfo: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let isUserProfile: Bool
}

/// 사용자의 Mac에 있는 Adobe·사용자 DCP를 찾아 읽는다. 파일은 읽기만 하고 복사하지 않는다.
/// 계약: docs/camera-profiles-calibration-contract.md
public final class CameraProfileLibrary: @unchecked Sendable {
    public static let defaultAdobeDirectory = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/CameraProfiles")
    public static let defaultUserDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Adobe/CameraRaw/CameraProfiles")
    public static let shared = CameraProfileLibrary()

    /// 큐브 격자 크기와 입력·출력 모양(0…4의 로그 곡선).
    static let cubeDimension = 64
    static let shaperRange = 4.0
    static let shaperGain = 32.0

    private let adobeDirectory: URL
    private let userDirectory: URL
    private let lock = NSLock()
    private var listings: [String: (stamp: String, profiles: [CameraProfileInfo])] = [:]
    private var parsed: [String: (stamp: Date?, profile: DNGProfile?)] = [:]
    private var cameras: [String: String?] = [:]
    private var cubes: [String: Data] = [:]
    private var cubeOrder: [String] = []

    public init(adobeDirectory: URL = CameraProfileLibrary.defaultAdobeDirectory,
                userDirectory: URL = CameraProfileLibrary.defaultUserDirectory) {
        self.adobeDirectory = adobeDirectory
        self.userDirectory = userDirectory
    }

    /// 카메라 이름이 DCP의 UniqueCameraModel과 같거나, 카메라 이름이 DCP 이름의 모델 부분(제조사 다음)으로 끝나면
    /// 맞는 프로필이다. EXIF 제조사가 "NIKON CORPORATION"처럼 Adobe 이름과 달라도 찾기 위해서다.
    static func matches(uniqueCameraModel: String, camera: String) -> Bool {
        let unique = uniqueCameraModel.trimmingCharacters(in: .whitespaces).lowercased()
        let name = camera.trimmingCharacters(in: .whitespaces).lowercased()
        guard !unique.isEmpty, !name.isEmpty else { return false }
        if unique == name { return true }
        guard let space = unique.firstIndex(of: " ") else { return false }
        let model = unique[unique.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return !model.isEmpty && name.hasSuffix(" " + model)
    }

    /// 이 카메라에 쓸 수 있는 프로필. 사용자 폴더가 같은 이름의 Adobe 프로필보다 앞선다.
    /// Adobe Standard가 먼저이고 나머지는 이름순이다.
    public func profiles(forCamera camera: String?) -> [CameraProfileInfo] {
        guard let camera, !camera.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let stamp = [userDirectory, adobeDirectory, adobeDirectory.appendingPathComponent("Camera")]
            .map { Self.modificationDate($0).map { String($0.timeIntervalSinceReferenceDate) } ?? "-" }
            .joined(separator: "|")
        lock.lock()
        if let cached = listings[camera], cached.stamp == stamp {
            lock.unlock()
            return cached.profiles
        }
        lock.unlock()
        var found: [CameraProfileInfo] = []
        for (directory, isUser) in [(userDirectory, true), (adobeDirectory, false)] {
            for url in Self.candidates(in: directory, camera: camera, includeAll: isUser) {
                guard let profile = load(url), let unique = profile.uniqueCameraModel,
                      Self.matches(uniqueCameraModel: unique, camera: camera),
                      !found.contains(where: { $0.name == profile.name }) else { continue }
                found.append(CameraProfileInfo(name: profile.name, url: url, isUserProfile: isUser))
            }
        }
        found.sort { lhs, rhs in
            if (lhs.name == "Adobe Standard") != (rhs.name == "Adobe Standard") { return lhs.name == "Adobe Standard" }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        lock.lock()
        listings[camera] = (stamp, found)
        lock.unlock()
        return found
    }

    /// 현상 캐시 키에 넣을 프로필 파일 식별값. 찾지 못하면 "missing"이다.
    func identity(name: String, camera: String?) -> String {
        guard let info = profiles(forCamera: camera).first(where: { $0.name == name }) else { return "missing" }
        let date = Self.modificationDate(info.url)?.timeIntervalSinceReferenceDate ?? 0
        return "\(info.url.path)|\(date)"
    }

    /// RAW 현상의 선형 단계에 넣을 필터. 프로필을 찾지 못하면 nil이다.
    func linearFilter(name: String, rawURL: URL, temperature: Double) -> (filter: CIFilter, hasToneCurve: Bool)? {
        let camera = camera(for: rawURL)
        let available = profiles(forCamera: camera)
        guard let info = available.first(where: { $0.name == name }), let profile = load(info.url) else { return nil }
        let reference = available.first(where: { $0.name == "Adobe Standard" }).flatMap { load($0.url) }
        let weight = (profile.illuminantWeight(temperature: temperature) * 20).rounded() / 20
        let key = "\(identity(name: name, camera: camera))|\(weight)"
        lock.lock()
        var cube = cubes[key]
        lock.unlock()
        if cube == nil {
            let representative = Self.temperature(forWeight: weight, profile: profile) ?? temperature
            let built = Self.cubeData(DNGProfileTransform(profile: profile, reference: reference,
                                                          temperature: representative))
            lock.lock()
            cubes[key] = built
            cubeOrder.removeAll { $0 == key }
            cubeOrder.append(key)
            while cubeOrder.count > 4 { cubes.removeValue(forKey: cubeOrder.removeFirst()) }
            lock.unlock()
            cube = built
        }
        guard let cube else { return nil }
        return (ShapedCubeFilter(cube: cube), profile.hasToneCurve)
    }

    /// 반올림한 가중치를 내는 색온도. 두 표준광 사이에서 역 색온도로 되돌린다.
    private static func temperature(forWeight weight: Double, profile: DNGProfile) -> Double? {
        guard let first = profile.illuminant1.flatMap(DNGProfile.temperature(ofIlluminant:)),
              let second = profile.illuminant2.flatMap(DNGProfile.temperature(ofIlluminant:)), first != second else {
            return nil
        }
        let inverse = weight / first + (1 - weight) / second
        return 1 / inverse
    }

    static func cubeData(_ transform: DNGProfileTransform) -> Data {
        let size = cubeDimension
        var values = [Float](repeating: 0, count: size * size * size * 4)
        var index = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let input = SIMD3(unshape(Double(r) / Double(size - 1)), unshape(Double(g) / Double(size - 1)),
                                      unshape(Double(b) / Double(size - 1)))
                    let output = transform.apply(input)
                    values[index] = Float(shape(output.x))
                    values[index + 1] = Float(shape(output.y))
                    values[index + 2] = Float(shape(output.z))
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func shape(_ x: Double) -> Double {
        min(1, log2(1 + shaperGain * max(0, x)) / log2(1 + shaperGain * shaperRange))
    }

    static func unshape(_ e: Double) -> Double {
        (pow(2, e * log2(1 + shaperGain * shaperRange)) - 1) / shaperGain
    }

    private func load(_ url: URL) -> DNGProfile? {
        let stamp = Self.modificationDate(url)
        lock.lock()
        if let cached = parsed[url.path], cached.stamp == stamp {
            lock.unlock()
            return cached.profile
        }
        lock.unlock()
        let profile = try? DNGProfile.load(url: url)
        lock.lock()
        parsed[url.path] = (stamp, profile)
        lock.unlock()
        return profile
    }

    /// 사진 파일의 "제조사 모델". `PhotoMetadata.camera`와 같은 방식이다.
    func camera(for url: URL) -> String? {
        lock.lock()
        if let cached = cameras[url.path] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var name: String?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let parts = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            name = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        lock.lock()
        cameras[url.path] = name
        lock.unlock()
        return name
    }

    /// Adobe 폴더는 파일이 수천 개라, 파일·폴더 이름의 카메라 이름이 맞는 파일만 연다.
    /// Adobe는 `Adobe Standard/<카메라> Adobe Standard.dcp`와 `Camera/<카메라>/…`로 둔다.
    private static func candidates(in directory: URL, camera: String, includeAll: Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "dcp" {
            if includeAll || matches(uniqueCameraModel: adobeCameraName(of: url), camera: camera) { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func adobeCameraName(of url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        if folder.deletingLastPathComponent().lastPathComponent == "Camera" { return folder.lastPathComponent }
        let file = url.deletingPathExtension().lastPathComponent
        return file.hasSuffix(" Adobe Standard") ? String(file.dropLast(" Adobe Standard".count)) : file
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// 0…4의 선형 값을 로그 모양으로 접어 64³ 큐브를 지나게 한다. CIRAWFilter의 `linearSpaceFilter`로 쓴다.
final class ShapedCubeFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    private let cube: Data

    init(cube: Data) {
        self.cube = cube
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var outputImage: CIImage? {
        guard let inputImage else { return nil }
        let gain = Float(CameraProfileLibrary.shaperGain)
        let range = Float(CameraProfileLibrary.shaperRange)
        guard let shape = CoreImageKernels.logShape, let unshape = CoreImageKernels.logUnshape,
              let shaped = shape.apply(extent: inputImage.extent, arguments: [inputImage, gain, range]) else {
            return inputImage
        }
        let filter = CIFilter.colorCube()
        filter.inputImage = shaped
        filter.cubeDimension = Float(CameraProfileLibrary.cubeDimension)
        filter.cubeData = cube
        guard let cubed = filter.outputImage else { return inputImage }
        return unshape.apply(extent: inputImage.extent, arguments: [cubed, gain, range])
    }
}
