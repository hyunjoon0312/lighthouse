import SwiftUI

/// 앱 전체의 색. 사진이 돋보이도록 어두운 바탕에 호박색 강조 하나만 둔다.
/// 강조색은 선택·현재 상태·주요 동작에만 쓰고, 경고는 시스템 주황(`warning`)으로 구분한다.
enum Palette {
    static let background = Color(red: 0.105, green: 0.112, blue: 0.122)
    static let panel = Color(red: 0.145, green: 0.152, blue: 0.164)
    static let canvas = Color(red: 0.085, green: 0.09, blue: 0.10)
    static let accent = Color(red: 1, green: 0.67, blue: 0.30)
    /// 고르지 않은 단추·목록 글자.
    static let inactive = Color.white.opacity(0.82)
    static let muted = Color.white.opacity(0.52)
    static let hairline = Color.white.opacity(0.08)
    static let warning = Color.orange
}
