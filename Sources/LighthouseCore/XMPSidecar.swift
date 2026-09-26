import Foundation

/// 별점·라벨·키워드·설명을 원본 옆 `<파일 이름>.xmp`(Adobe 방식)로 남겨 다른 사진 앱에서 읽게 한다.
/// 원본 파일은 건드리지 않는다. 이미 있는 사이드카는 Lighthouse가 쓴 것일 때만 덮어쓴다.
public enum XMPSidecar {
    public static let creatorTool = "Lighthouse"

    public enum Outcome: Equatable, Sendable {
        case written
        /// 쓸 것이 없었다. 내용이 같거나, 사이드카가 없고 적을 표시도 없다.
        case unchanged
        /// 다른 프로그램이 만든 사이드카라 덮어쓰지 않았다.
        case foreign
        case failed(String)
    }

    /// 원본과 같은 폴더의 같은 이름 `.xmp`.
    public static func url(for photo: PhotoAsset) -> URL {
        photo.url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// 사이드카에 적는 값. 이미 있는 사이드카를 다시 읽어 Lighthouse가 쓴 모양인지 확인할 때도 쓴다.
    struct Marks: Equatable {
        var rating: Int
        var label: String?
        var keywords: [String]
        var caption: String

        /// 적을 표시가 하나도 없다.
        var isEmpty: Bool { rating == 0 && label == nil && keywords.isEmpty && caption.isEmpty }
    }

    /// 제외는 Lightroom처럼 별점 -1로 쓴다. 선택 표시는 XMP에 정해진 항목이 없어 쓰지 않는다.
    static func marks(of photo: PhotoAsset) -> Marks {
        Marks(rating: photo.flag == .reject ? -1 : photo.rating, label: photo.colorLabel?.xmpName,
              keywords: photo.keywords, caption: photo.caption)
    }

    public static func document(for photo: PhotoAsset) -> String {
        document(marks(of: photo))
    }

    static func document(_ marks: Marks) -> String {
        var attributes = "    xmp:CreatorTool=\"\(creatorTool)\"\n    xmp:Rating=\"\(marks.rating)\""
        if let label = marks.label { attributes += "\n    xmp:Label=\"\(escaped(label))\"" }
        var body = ""
        if !marks.keywords.isEmpty {
            body += "   <dc:subject>\n    <rdf:Bag>\n" +
                marks.keywords.map { "     <rdf:li>\(escaped($0))</rdf:li>\n" }.joined() +
                "    </rdf:Bag>\n   </dc:subject>\n"
        }
        if !marks.caption.isEmpty {
            body += "   <dc:description>\n    <rdf:Alt>\n" +
                "     <rdf:li xml:lang=\"x-default\">\(escaped(marks.caption))</rdf:li>\n" +
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

    /// 사이드카가 없거나 Lighthouse가 쓴 것이면 쓴다. 사이드카가 없고 적을 표시(별점·제외·라벨·키워드·설명)도 없으면
    /// 만들지 않아 표시하지 않은 사진 옆에 파일이 생기지 않는다. 원본 폴더가 없으면(원본 없음) 실패다.
    public static func write(_ photo: PhotoAsset) -> Outcome {
        let target = url(for: photo)
        let marks = marks(of: photo)
        let data = Data(document(marks).utf8)
        if let existing = try? Data(contentsOf: target) {
            guard isOurs(existing) else { return .foreign }
            if existing == data { return .unchanged }
        } else if marks.isEmpty {
            return .unchanged
        }
        do {
            try data.write(to: target, options: .atomic)
            return .written
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Lighthouse가 쓴 모양 그대로일 때만 우리 것이다. 다른 프로그램이 항목(보정값 등)을 더하거나 고쳐 저장한 파일은
    /// `CreatorTool`이 남아 있어도 덮어쓰면 그 내용이 사라지므로 우리 것으로 보지 않는다.
    static func isOurs(_ data: Data) -> Bool {
        guard let marks = marks(in: data) else { return false }
        return Data(document(marks).utf8) == data
    }

    /// 사이드카에서 Lighthouse가 쓰는 항목만 읽는다. `CreatorTool`이 Lighthouse가 아니거나 읽을 수 없으면 nil.
    static func marks(in data: Data) -> Marks? {
        guard let xml = try? XMLDocument(data: data),
              let description = (try? xml.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement,
              description.attribute(forName: "xmp:CreatorTool")?.stringValue == creatorTool,
              let rating = description.attribute(forName: "xmp:Rating")?.stringValue.flatMap({ Int($0) }) else {
            return nil
        }
        func texts(_ path: String) -> [String] {
            ((try? description.nodes(forXPath: path)) ?? []).compactMap(\.stringValue)
        }
        return Marks(rating: rating, label: description.attribute(forName: "xmp:Label")?.stringValue,
                     keywords: texts("./*[local-name()='subject']//*[local-name()='li']"),
                     caption: texts("./*[local-name()='description']//*[local-name()='li']").first ?? "")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
