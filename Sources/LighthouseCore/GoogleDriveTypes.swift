import Foundation

public struct GoogleDriveFile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let webViewLink: String?

    public init(id: String, name: String, webViewLink: String? = nil) {
        self.id = id
        self.name = name
        self.webViewLink = webViewLink
    }
}

public struct GoogleDriveAccount: Codable, Equatable, Sendable {
    public let displayName: String
    public let emailAddress: String

    public init(displayName: String, emailAddress: String) {
        self.displayName = displayName
        self.emailAddress = emailAddress
    }
}

public protocol GoogleDriveServicing: Sendable {
    func account(accessToken: String) async throws -> GoogleDriveAccount
    func folders(accessToken: String) async throws -> [GoogleDriveFile]
    func createFolder(name: String, accessToken: String) async throws -> GoogleDriveFile
    func upload(fileURL: URL, name: String, mimeType: String, parentID: String,
                accessToken: String) async throws -> GoogleDriveFile
}

public enum GoogleDriveError: Error, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case cancelled
    case uploadCompletionUnknown
    case invalidFolderName
    case invalidFile
    case invalidUploadLocation

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google Drive에서 올바른 응답을 받지 못했습니다."
        case .httpStatus(401):
            "Google Drive 연결이 만료되었습니다. 다시 연결해 주세요."
        case .httpStatus(403):
            "Google Drive 권한 또는 저장 공간을 확인해 주세요."
        case .httpStatus(429):
            "Google Drive 요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요."
        case .httpStatus(let status):
            "Google Drive 요청에 실패했습니다. (HTTP \(status))"
        case .cancelled:
            "Google Drive 작업이 취소되었습니다."
        case .uploadCompletionUnknown:
            "업로드 응답이 중단되었습니다. Drive에서 완료 여부를 확인한 뒤 다시 시도해 주세요."
        case .invalidFolderName:
            "폴더 이름은 1자 이상 200자 이하로 입력해 주세요."
        case .invalidFile:
            "업로드할 파일이 없거나 비어 있습니다."
        case .invalidUploadLocation:
            "Google Drive 업로드 주소를 확인할 수 없습니다."
        }
    }
}
