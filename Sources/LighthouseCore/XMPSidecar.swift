import Foundation

/// 별점·라벨·키워드·설명을 원본 옆 `<파일 이름>.xmp`(Adobe 방식)로 남겨 다른 사진 앱에서 읽게 한다.
/// 원본 파일은 건드리지 않는다. 이미 있는 사이드카는 Lighthouse가 쓴 것일 때만 덮어쓴다.
public enum XMPSidecar {
    public static let creatorTool = "Lighthouse"

    public enum Outcome: Equatable, Sendable {
        case written
        /// 내용이 같아 다시 쓰지 않았다.
        case unchanged
        /// 다른 프로그램이 만든 사이드카라 덮어쓰지 않았다.
        case foreign
        case failed(String)
    }

    /// 원본과 같은 폴더의 같은 이름 `.xmp`.
    public static func url(for photo: PhotoAsset) -> URL {
        photo.url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 제외는 Lightroom처럼 별점 -1로 쓴다. 선택 표시는 XMP에 정해진 항목이 없어 쓰지 않는다.
    public static func document(for photo: PhotoAsset) -> String {
        let rating = photo.flag == .reject ? -1 : photo.rating
        var attributes = "    xmp:CreatorTool=\"\(creatorTool)\"\n    xmp:Rating=\"\(rating)\""
        if let label = photo.colorLabel { attributes += "\n    xmp:Label=\"\(label.xmpName)\"" }
        var body = ""
        if !photo.keywords.isEmpty {
            body += "   <dc:subject>\n    <rdf:Bag>\n" +
                photo.keywords.map { "     <rdf:li>\(escaped($0))</rdf:li>\n" }.joined() +
                "    </rdf:Bag>\n   </dc:subject>\n"
        }
        if !photo.caption.isEmpty {
            body += "   <dc:description>\n    <rdf:Alt>\n" +
                "     <rdf:li xml:lang=\"x-default\">\(escaped(photo.caption))</rdf:li>\n" +
                "    </rdf:Alt>\n   </dc:description>\n"
        }
        return """
            <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="\(creatorTool)">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:dc="http://purl.org/dc/elements/1.1/"
            \(attributes)>
            \(body)  </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            <?xpacket end="w"?>

            """
    }

    /// 사이드카가 없거나 Lighthouse가 쓴 것이면 쓴다. 원본 폴더가 없으면(원본 없음) 실패다.
    public static func write(_ photo: PhotoAsset) -> Outcome {
        let target = url(for: photo)
        let data = Data(document(for: photo).utf8)
        if let existing = try? Data(contentsOf: target) {
            guard isOurs(existing) else { return .foreign }
            if existing == data { return .unchanged }
        }
        do {
            try data.write(to: target, options: .atomic)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func isOurs(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).contains("xmp:CreatorTool=\"\(creatorTool)\"")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
