import SwiftUI

/// 오래 도는 작업의 진행값. 파일 한 장·컷 하나마다 바뀌므로 `LibraryModel`에서 떼어 두고 진행 막대와 작업 목록만
/// 지켜보게 한다. 모델의 `operationProgress` 같은 이름으로도 읽고 쓸 수 있다.
@MainActor
final class JobProgress: ObservableObject {
    /// 가져오기·내보내기. 0…1.
    @Published var operation = 0.0
    /// 가져오는 동안 몇 번째 파일인지("가져오는 중 3/10"). 상태 줄에서 안내 문구 대신 보이며, 새 안내가 오면 지운다.
    @Published var operationStep: String?
    /// 여러 장에 하는 묶음 작업. 0…1.
    @Published var workflow = 0.0
    @Published var facesCompleted = 0
    @Published var facesTotal = 0
    /// 베스트 컷 분석. 0…1.
    @Published var bursts = 0.0
}

/// 진행값 하나를 막대로 보인다. 이 막대만 진행을 지켜보므로 값이 바뀌어도 둘러싼 화면은 다시 계산되지 않는다.
struct JobProgressBar: View {
    @ObservedObject var progress: JobProgress
    let value: KeyPath<JobProgress, Double>

    var body: some View {
        ProgressView(value: progress[keyPath: value])
    }
}
