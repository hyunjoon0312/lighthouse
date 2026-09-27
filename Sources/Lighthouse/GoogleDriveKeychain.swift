import Foundation
import Security

struct GoogleDriveOAuthConfiguration: Codable, Equatable, Sendable {
    let clientID: String
    let clientSecret: String?
}

struct GoogleDriveOAuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date
}

struct GoogleDriveStoredAuthorization: Codable, Equatable, Sendable {
    let configuration: GoogleDriveOAuthConfiguration
    let tokens: GoogleDriveOAuthTokens?
}

protocol GoogleDriveCredentialStoring: Sendable {
    func load() throws -> GoogleDriveStoredAuthorization?
    func save(_ authorization: GoogleDriveStoredAuthorization) throws
}

enum GoogleDriveKeychainError: Error, LocalizedError, Equatable, Sendable {
    case unexpectedData
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "Google Drive 연결 정보를 키체인에서 읽을 수 없습니다."
        case .operationFailed:
            return "Google Drive 연결 정보를 키체인에 저장할 수 없습니다."
        }
    }
}

final class GoogleDriveKeychainStore: GoogleDriveCredentialStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "\(Bundle.main.bundleIdentifier ?? "com.rian.Lighthouse").google-drive.oauth",
        account: String = "authorization"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> GoogleDriveStoredAuthorization? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw GoogleDriveKeychainError.operationFailed(status)
        }
        guard let data = result as? Data else {
            throw GoogleDriveKeychainError.unexpectedData
        }
        do {
            return try JSONDecoder().decode(GoogleDriveStoredAuthorization.self, from: data)
        } catch {
            throw GoogleDriveKeychainError.unexpectedData
        }
    }

    func save(_ authorization: GoogleDriveStoredAuthorization) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(authorization)
        } catch {
            throw GoogleDriveKeychainError.unexpectedData
        }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GoogleDriveKeychainError.operationFailed(updateStatus)
        }

        var insertion = baseQuery
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GoogleDriveKeychainError.operationFailed(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
