import Foundation

/// 카메라가 RAW와 함께 저장한 JPEG·HEIF. 같은 폴더·같은 이름(대소문자 무시)의 RAW가 있는 원래 항목이다.
public enum RAWJPEGPairs {
    private static let companionExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif"]

    /// 짝 파일 ID → 같은 이름의 RAW ID들. 가상 사본은 따로 만든 보정이므로 넣지 않는다.
    public static func companions(in photos: [PhotoAsset]) -> [UUID: [UUID]] {
        var rawsByStem: [String: [UUID]] = [:]
        for photo in photos where !photo.isVirtualCopy && photo.isRAW {
            rawsByStem[stem(of: photo.path), default: []].append(photo.id)
        }
        guard !rawsByStem.isEmpty else { return [:] }
        var result: [UUID: [UUID]] = [:]
        for photo in photos where !photo.isVirtualCopy && !photo.isRAW {
            let ext = (photo.path as NSString).pathExtension.lowercased()
            if companionExtensions.contains(ext), let raws = rawsByStem[stem(of: photo.path)] { result[photo.id] = raws }
        }
        return result
    }

    static func stem(of path: String) -> String {
        (path as NSString).deletingPathExtension.lowercased()
    }
}
