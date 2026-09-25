import os

/// 실패를 macOS 통합 로그에 남겨 나중에 원인을 찾을 수 있게 한다. 파일 이름·경로와 오류 설명(경로가 들어갈 수 있음)은
/// `.private`로 남겨 이 Mac에서 디버깅할 때만 보인다. 사진이나 보정값은 남기지 않는다.
/// `log stream --level info --predicate 'subsystem == "com.rian.lighthouse"'`로 볼 수 있다.
enum AppLog {
    private static let subsystem = "com.rian.lighthouse"
    static let catalog = Logger(subsystem: subsystem, category: "catalog")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let editing = Logger(subsystem: subsystem, category: "editing")
    static let export = Logger(subsystem: subsystem, category: "export")
}
