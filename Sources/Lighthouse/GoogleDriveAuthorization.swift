import AppKit
import CryptoKit
import Foundation
import Security

@MainActor
protocol GoogleDriveAuthorizing: AnyObject {
    var isConfigured: Bool { get }
    var isConnected: Bool { get }
    func restore() throws
    func configure(json: Data) throws
    func signIn() async throws
    func accessToken(forceRefresh: Bool) async throws -> String
    func disconnect() throws
}

protocol GoogleDriveBrowserOpening: Sendable {
    @MainActor func open(_ url: URL) -> Bool
}

struct GoogleDriveSystemBrowser: GoogleDriveBrowserOpening {
    @MainActor
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

enum GoogleDriveAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case notConfigured
    case notConnected
    case operationInProgress
    case browserOpenFailed
    case invalidTokenResponse
    case missingRefreshToken
    case insufficientScope
    case invalidGrant
    case requestFailed(Int)
    case staleOperation
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Google 데스크톱 앱 OAuth JSON이 올바르지 않습니다."
        case .notConfigured:
            return "먼저 Google 데스크톱 앱 OAuth JSON을 선택해 주세요."
        case .notConnected, .missingRefreshToken, .invalidGrant:
            return "Google Drive에 다시 연결해 주세요."
        case .operationInProgress:
            return "다른 Google Drive 연결 작업이 진행 중입니다."
        case .browserOpenFailed:
            return "Google 로그인 페이지를 열 수 없습니다."
        case .invalidTokenResponse:
            return "Google 로그인 응답을 확인할 수 없습니다."
        case .insufficientScope:
            return "Google Drive 파일 권한이 승인되지 않았습니다."
        case .requestFailed(let status):
            return "Google 로그인 요청에 실패했습니다. (HTTP \(status))"
        case .staleOperation:
            return "연결 설정이 변경되어 진행 중인 작업을 취소했습니다."
        case .cancelled:
            return "Google Drive 연결 작업이 취소되었습니다."
        }
    }
}

@MainActor
final class GoogleDriveAuthorization: GoogleDriveAuthorizing {
    static let driveFileScope = "https://www.googleapis.com/auth/drive.file"

    private let store: any GoogleDriveCredentialStoring
    private let session: URLSession
    private let browser: any GoogleDriveBrowserOpening
    private let loopbackFactory: @Sendable (String) -> any GoogleDriveLoopbackServing
    private let randomBytes: @Sendable (Int) throws -> Data
    private let now: @Sendable () -> Date

    private var storedAuthorization: GoogleDriveStoredAuthorization?
    private var generation = 0
    private var operationID: UUID?
    private var activeLoopback: (any GoogleDriveLoopbackServing)?

    var isConfigured: Bool { storedAuthorization != nil }
    var isConnected: Bool { storedAuthorization?.tokens != nil }

    init(
        store: any GoogleDriveCredentialStoring = GoogleDriveKeychainStore(),
        session: URLSession? = nil,
        browser: any GoogleDriveBrowserOpening = GoogleDriveSystemBrowser(),
        loopbackFactory: @escaping @Sendable (String) -> any GoogleDriveLoopbackServing = {
            GoogleDriveLoopbackServer(expectedState: $0)
        },
        randomBytes: @escaping @Sendable (Int) throws -> Data = GoogleDriveAuthorization.secureRandomBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.session = session ?? Self.makeProductionSession()
        self.browser = browser
        self.loopbackFactory = loopbackFactory
        self.randomBytes = randomBytes
        self.now = now
    }

    func restore() throws {
        let restored = try store.load()
        invalidateCurrentOperation()
        storedAuthorization = restored
    }

    func configure(json: Data) throws {
        let configuration = try Self.parseConfiguration(json)
        let replacement = GoogleDriveStoredAuthorization(configuration: configuration, tokens: nil)
        try store.save(replacement)
        invalidateCurrentOperation()
        storedAuthorization = replacement
    }

    func signIn() async throws {
        guard let configuration = storedAuthorization?.configuration else {
            throw GoogleDriveAuthorizationError.notConfigured
        }
        let operation = try beginOperation()
        let operationGeneration = generation
        defer { finishOperation(operation) }

        do {
            let verifier = Self.base64URLEncoded(try randomBytes(32))
            guard verifier.count == 43 else {
                throw GoogleDriveAuthorizationError.invalidTokenResponse
            }
            let challenge = Self.base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
            let state = Self.base64URLEncoded(try randomBytes(32))
            guard !state.isEmpty else {
                throw GoogleDriveAuthorizationError.invalidTokenResponse
            }

            let loopback = loopbackFactory(state)
            activeLoopback = loopback
            defer {
                loopback.cancel()
                if operationID == operation {
                    activeLoopback = nil
                }
            }

            let redirectURI = try await loopback.start()
            try validateCurrent(operation: operation, generation: operationGeneration)
            let authorizationURL = try Self.authorizationURL(
                configuration: configuration,
                redirectURI: redirectURI,
                state: state,
                codeChallenge: challenge
            )
            guard browser.open(authorizationURL) else {
                throw GoogleDriveAuthorizationError.browserOpenFailed
            }

            let code = try await loopback.waitForCode(timeoutSeconds: 180)
            try validateCurrent(operation: operation, generation: operationGeneration)
            let response = try await requestToken(form: Self.authorizationCodeForm(
                configuration: configuration,
                code: code,
                verifier: verifier,
                redirectURI: redirectURI
            ))
            try validateCurrent(operation: operation, generation: operationGeneration)
            let tokens = try Self.tokens(from: response, preservingRefreshToken: nil, now: now())
            let connected = GoogleDriveStoredAuthorization(configuration: configuration, tokens: tokens)
            try store.save(connected)
            try validateCurrent(operation: operation, generation: operationGeneration)
            storedAuthorization = connected
        } catch is CancellationError {
            throw GoogleDriveAuthorizationError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GoogleDriveAuthorizationError.cancelled
        } catch let error as GoogleDriveLoopbackError where error == .cancelled {
            throw GoogleDriveAuthorizationError.cancelled
        }
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let current = storedAuthorization, let tokens = current.tokens else {
            throw GoogleDriveAuthorizationError.notConnected
        }
        if !forceRefresh, tokens.expirationDate.timeIntervalSince(now()) > 60 {
            return tokens.accessToken
        }
        guard !tokens.refreshToken.isEmpty else {
            throw GoogleDriveAuthorizationError.missingRefreshToken
        }

        let operation = try beginOperation()
        let operationGeneration = generation
        defer { finishOperation(operation) }
        do {
            let response = try await requestToken(form: Self.refreshForm(
                configuration: current.configuration,
                refreshToken: tokens.refreshToken
            ))
            try validateCurrent(operation: operation, generation: operationGeneration)
            let refreshedTokens = try Self.tokens(
                from: response,
                preservingRefreshToken: tokens.refreshToken,
                now: now()
            )
            let refreshed = GoogleDriveStoredAuthorization(
                configuration: current.configuration,
                tokens: refreshedTokens
            )
            try store.save(refreshed)
            try validateCurrent(operation: operation, generation: operationGeneration)
            storedAuthorization = refreshed
            return refreshedTokens.accessToken
        } catch GoogleDriveAuthorizationError.invalidGrant {
            do {
                try validateCurrent(operation: operation, generation: operationGeneration)
            } catch is CancellationError {
                throw GoogleDriveAuthorizationError.cancelled
            }
            let disconnected = GoogleDriveStoredAuthorization(
                configuration: current.configuration,
                tokens: nil
            )
            storedAuthorization = disconnected
            generation += 1
            try store.save(disconnected)
            throw GoogleDriveAuthorizationError.invalidGrant
        } catch is CancellationError {
            throw GoogleDriveAuthorizationError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GoogleDriveAuthorizationError.cancelled
        }
    }

    func disconnect() throws {
        guard let configuration = storedAuthorization?.configuration else {
            return
        }
        let disconnected = GoogleDriveStoredAuthorization(configuration: configuration, tokens: nil)
        try store.save(disconnected)
        invalidateCurrentOperation()
        storedAuthorization = disconnected
    }

    private func requestToken(form: [String: String]) async throws -> OAuthTokenResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(form)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveAuthorizationError.invalidTokenResponse
        }
        guard http.statusCode == 200 else {
            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
               oauthError.error == "invalid_grant" {
                throw GoogleDriveAuthorizationError.invalidGrant
            }
            throw GoogleDriveAuthorizationError.requestFailed(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        } catch {
            throw GoogleDriveAuthorizationError.invalidTokenResponse
        }
    }

    private func beginOperation() throws -> UUID {
        guard operationID == nil else {
            throw GoogleDriveAuthorizationError.operationInProgress
        }
        let id = UUID()
        operationID = id
        return id
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        activeLoopback = nil
    }

    private func invalidateCurrentOperation() {
        generation += 1
        activeLoopback?.cancel()
        activeLoopback = nil
        operationID = nil
    }

    private func validateCurrent(operation: UUID, generation expectedGeneration: Int) throws {
        try Task.checkCancellation()
        guard operationID == operation, generation == expectedGeneration else {
            throw GoogleDriveAuthorizationError.staleOperation
        }
    }

    static func parseConfiguration(_ data: Data) throws -> GoogleDriveOAuthConfiguration {
        let document: OAuthClientDocument
        do {
            document = try JSONDecoder().decode(OAuthClientDocument.self, from: data)
        } catch {
            throw GoogleDriveAuthorizationError.invalidConfiguration
        }
        guard document.web == nil,
              let installed = document.installed,
              let clientID = normalizedClientID(installed.clientID)
        else {
            throw GoogleDriveAuthorizationError.invalidConfiguration
        }
        let secret = installed.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GoogleDriveOAuthConfiguration(
            clientID: clientID,
            clientSecret: secret?.isEmpty == false ? secret : nil
        )
    }

    private static func normalizedClientID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        let prefix = trimmed.dropLast(suffix.count)
        guard trimmed == value,
              trimmed.count > suffix.count,
              trimmed.hasSuffix(suffix),
              prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            return nil
        }
        return trimmed
    }

    static func authorizationURL(
        configuration: GoogleDriveOAuthConfiguration,
        redirectURI: URL,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        guard redirectURI.scheme == "http",
              redirectURI.host == "127.0.0.1",
              redirectURI.port != nil,
              redirectURI.path == "/",
              redirectURI.user == nil,
              redirectURI.password == nil,
              redirectURI.fragment == nil
        else {
            throw GoogleDriveAuthorizationError.invalidConfiguration
        }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: driveFileScope),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            throw GoogleDriveAuthorizationError.invalidConfiguration
        }
        return url
    }

    static func authorizationCodeForm(
        configuration: GoogleDriveOAuthConfiguration,
        code: String,
        verifier: String,
        redirectURI: URL
    ) -> [String: String] {
        var form = [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString,
        ]
        if let clientSecret = configuration.clientSecret {
            form["client_secret"] = clientSecret
        }
        return form
    }

    static func refreshForm(
        configuration: GoogleDriveOAuthConfiguration,
        refreshToken: String
    ) -> [String: String] {
        var form = [
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if let clientSecret = configuration.clientSecret {
            form["client_secret"] = clientSecret
        }
        return form
    }

    static func formEncoded(_ form: [String: String]) -> Data {
        let value = form.keys.sorted().map { key in
            "\(percentEncoded(key))=\(percentEncoded(form[key]!))"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func percentEncoded(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func tokens(
        from response: OAuthTokenResponse,
        preservingRefreshToken oldRefreshToken: String?,
        now: Date
    ) throws -> GoogleDriveOAuthTokens {
        guard !response.accessToken.isEmpty,
              response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              response.expiresIn > 0
        else {
            throw GoogleDriveAuthorizationError.invalidTokenResponse
        }
        if let scope = response.scope {
            let scopes = Set(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            guard scopes.contains(driveFileScope) else {
                throw GoogleDriveAuthorizationError.insufficientScope
            }
        }
        let refreshToken = response.refreshToken ?? oldRefreshToken
        guard let refreshToken, !refreshToken.isEmpty else {
            throw GoogleDriveAuthorizationError.missingRefreshToken
        }
        return GoogleDriveOAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expirationDate: now.addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    nonisolated private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw GoogleDriveAuthorizationError.invalidTokenResponse
        }
        return data
    }

    private static func makeProductionSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
}

private struct OAuthClientDocument: Decodable {
    let installed: OAuthClient?
    let web: OAuthClient?
}

private struct OAuthClient: Decodable {
    let clientID: String
    let clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double
    let refreshToken: String?
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
