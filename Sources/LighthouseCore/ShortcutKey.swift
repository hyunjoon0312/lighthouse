import Foundation

/// 한 글자 단축키를 입력 소스와 상관없이 같은 키로 읽는다. 한글 입력 상태에서는 P 키가 "ㅔ"로 들어오므로
/// 입력된 글자가 영문·숫자·기호가 아니면 키 위치(QWERTY 기준)로 판단한다. Dvorak처럼 영문 배열이 다르면 글자를 따른다.
public enum ShortcutKey {
    private static let qwerty: [UInt16: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l",
        46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9", 42: "\\"
    ]

    public static func resolve(characters: String?, keyCode: UInt16) -> String? {
        if let characters, characters.count == 1, let scalar = characters.unicodeScalars.first,
           scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(characters) || characters == "\\" {
            return characters.lowercased()
        }
        return qwerty[keyCode]
    }
}
