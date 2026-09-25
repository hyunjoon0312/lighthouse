import Foundation

/// 옮겨진 원본을 새 폴더에서 다시 찾는다. 사진 하나가 새 폴더 아래 어디에 있는지로 옛 폴더와 새 폴더의
/// 대응을 정하고, 같은 옛 폴더 아래의 다른 사진도 그 대응으로 찾는다.
public enum PhotoRelocation {
    /// `missingPath`의 파일을 `folder` 바로 아래, 그다음 옛 부모 폴더 이름을 하나씩 붙인 위치에서 찾는다.
    /// 그래서 파일이 든 폴더를 골라도, 그 상위 폴더를 골라도 된다. 찾으면 옛 접두사와 새 접두사를 돌려준다.
    public static func mapping(for missingPath: String, in folder: String,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (from: String, to: String)? {
        let components = (missingPath as NSString).pathComponents
        guard components.count >= 2 else { return nil }
        for kept in 1..<components.count {
            let tail = NSString.path(withComponents: Array(components.suffix(kept)))
            guard fileExists((folder as NSString).appendingPathComponent(tail)) else { continue }
            return (NSString.path(withComponents: Array(components.dropLast(kept))), folder)
        }
        return nil
    }

    /// 대응을 적용한 새 경로. `path`가 옛 접두사 아래가 아니면 nil.
    public static func relocated(_ path: String, from: String, to: String) -> String? {
        let prefix = from.hasSuffix("/") ? from : from + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return (to as NSString).appendingPathComponent(String(path.dropFirst(prefix.count)))
    }
}
