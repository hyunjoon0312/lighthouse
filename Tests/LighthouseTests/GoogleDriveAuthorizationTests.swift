import CryptoKit
import Foundation
import XCTest
@testable import Lighthouse

@MainActor
final class GoogleDriveAuthorizationTests: XCTestCase {
    override func tearDown() {
        TestURLProtocol.handler = nil
        DelayedURLProtocol.reset()
        super.tearDown()
    }

    func testPKCERFC7636VectorAndBase64URLLength() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        XCTAssertEqual(GoogleDriveAuthorization.base64URLEncoded(digest), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(GoogleDriveAuthorization.base64URLEncoded(Data(repeating: 0xA5, count: 32)).count, 43)
    }

    func testAuthorizationQueryUsesOnlyNativeFlowAndDriveFileScope() throws {
        let url = try GoogleDriveAuthorization.authorizationURL(
            configuration: configuration,
            redirectURI: URL(string: "http://127.0.0.1:54321/")!,
            state: "state +/한글",
            codeChallenge: "challenge-_"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(items["scope"], GoogleDriveAuthorization.driveFileScope)
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:54321/")
        XCTAssertEqual(items["state"], "state +/한글")
    }

    func testFormEncodingEscapesReservedAndUnicodeBytes() {
        let encoded = String(data: GoogleDriveAuthorization.formEncoded([
            "a key": "a+b/c=한글",
            "z": "~ ok",
        ]), encoding: .utf8)
        XCTAssertEqual(encoded, "a%20key=a%2Bb%2Fc%3D%ED%95%9C%EA%B8%80&z=~%20ok")
    }

    func testCallbackRequiresRootPathSingleMatchingStateAndCode() {
        XCTAssertEqual(
            callback("GET /?code=abc%2B123&state=expected HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
            .code("abc+123")
        )
        XCTAssertEqual(callback("GET /other?code=abc&state=expected HTTP/1.1\r\n\r\n"), .invalid)
        XCTAssertEqual(callback("GET /?code=abc&state=wrong HTTP/1.1\r\n\r\n"), .invalid)
        XCTAssertEqual(callback("GET /?code=abc&state=expected&state=expected HTTP/1.1\r\n\r\n"), .invalid)
        XCTAssertEqual(callback("GET /?code=one&code=two&state=expected HTTP/1.1\r\n\r\n"), .invalid)
        XCTAssertEqual(callback("GET /?code=one&error=first&error=second&state=expected HTTP/1.1\r\n\r\n"), .invalid)
        XCTAssertEqual(callback("GET /?error=first&error=second&state=expected HTTP/1.1\r\n\r\n"), .invalid)
        XCTAssertEqual(callback("GET /?error=access_denied&state=expected HTTP/1.1\r\n\r\n"), .authorizationError)
        XCTAssertEqual(
            GoogleDriveLoopbackRequest.parse(
                header: Data(repeating: 0x41, count: GoogleDriveLoopbackServer.maximumHeaderBytes + 1),
                expectedState: "expected"
            ),
            .invalid
        )
    }

    func testConfigurationAcceptsInstalledAndIgnoresProvidedURLs() throws {
        let data = Data("""
        {"installed":{"client_id":"123.apps.googleusercontent.com","client_secret":"secret","auth_uri":"https://attacker.invalid/authorize","token_uri":"https://attacker.invalid/token","redirect_uris":["https://attacker.invalid/callback"]}}
        """.utf8)
        XCTAssertEqual(
            try GoogleDriveAuthorization.parseConfiguration(data),
            GoogleDriveOAuthConfiguration(clientID: "123.apps.googleusercontent.com", clientSecret: "secret")
        )
    }

    func testConfigurationRejectsWebOnlyAndMalformedClientID() {
        XCTAssertThrowsError(try GoogleDriveAuthorization.parseConfiguration(Data("""
        {"web":{"client_id":"123.apps.googleusercontent.com"}}
        """.utf8)))
        XCTAssertThrowsError(try GoogleDriveAuthorization.parseConfiguration(Data("""
        {"installed":{"client_id":"not-a-google-client"}}
        """.utf8)))
        XCTAssertThrowsError(try GoogleDriveAuthorization.parseConfiguration(Data("""
        {"installed":{"client_id":"bad/path.apps.googleusercontent.com"}}
        """.utf8)))
    }

    func testConfigureAtomicallyReplacesCredentialsAndClearsTokens() throws {
        let store = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: expiredTokens
        ))
        let authorization = GoogleDriveAuthorization(store: store)
        try authorization.restore()
        try authorization.configure(json: Data("""
        {"installed":{"client_id":"replacement.apps.googleusercontent.com"}}
        """.utf8))

        XCTAssertTrue(authorization.isConfigured)
        XCTAssertFalse(authorization.isConnected)
        XCTAssertEqual(store.value?.configuration.clientID, "replacement.apps.googleusercontent.com")
        XCTAssertNil(store.value?.tokens)
    }

    func testRefreshPreservesExistingRefreshToken() async throws {
        let store = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: expiredTokens
        ))
        TestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                try Self.requestBody(request),
                "client_id=123.apps.googleusercontent.com&client_secret=client-secret&grant_type=refresh_token&refresh_token=refresh-old"
            )
            return Self.response(
                request: request,
                status: 200,
                body: #"{"access_token":"access-new","expires_in":3600,"token_type":"Bearer"}"#
            )
        }
        let authorization = GoogleDriveAuthorization(
            store: store,
            session: makeSession(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        try authorization.restore()

        let accessToken = try await authorization.accessToken(forceRefresh: false)
        XCTAssertEqual(accessToken, "access-new")
        XCTAssertEqual(store.value?.tokens?.refreshToken, "refresh-old")
        XCTAssertEqual(store.value?.tokens?.expirationDate, Date(timeIntervalSince1970: 4_600))
    }

    func testInvalidGrantClearsStoredAndInMemoryTokens() async throws {
        let store = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: expiredTokens
        ))
        TestURLProtocol.handler = { request in
            Self.response(request: request, status: 400, body: #"{"error":"invalid_grant"}"#)
        }
        let authorization = GoogleDriveAuthorization(store: store, session: makeSession())
        try authorization.restore()

        do {
            _ = try await authorization.accessToken(forceRefresh: true)
            XCTFail("Expected invalid_grant")
        } catch {
            XCTAssertEqual(error as? GoogleDriveAuthorizationError, .invalidGrant)
        }
        XCTAssertFalse(authorization.isConnected)
        XCTAssertNil(store.value?.tokens)
        XCTAssertTrue(authorization.isConfigured)
    }

    func testDelayedInvalidGrantCannotOverwriteReconfiguredCredentials() async throws {
        let store = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: expiredTokens
        ))
        let authorization = GoogleDriveAuthorization(store: store, session: makeDelayedSession())
        try authorization.restore()

        let refresh = Task { try await authorization.accessToken(forceRefresh: true) }
        while !DelayedURLProtocol.hasPendingRequest {
            await Task.yield()
        }
        try authorization.configure(json: Data("""
        {"installed":{"client_id":"replacement.apps.googleusercontent.com"}}
        """.utf8))
        DelayedURLProtocol.respond(
            status: 400,
            body: #"{"error":"invalid_grant"}"#
        )

        do {
            _ = try await refresh.value
            XCTFail("Expected stale operation")
        } catch {
            XCTAssertEqual(error as? GoogleDriveAuthorizationError, .staleOperation)
        }
        XCTAssertEqual(store.value?.configuration.clientID, "replacement.apps.googleusercontent.com")
        XCTAssertNil(store.value?.tokens)
        XCTAssertTrue(authorization.isConfigured)
    }

    func testActualLoopbackRejectsInvalidCallbackThenCompletesOnce() async throws {
        let server = GoogleDriveLoopbackServer(expectedState: "expected")
        let redirect = try await server.start()
        let waiting = Task { try await server.waitForCode(timeoutSeconds: 2) }

        let invalidURL = try XCTUnwrap(URL(string: "?code=bad&state=wrong", relativeTo: redirect)?.absoluteURL)
        let (_, invalidResponse) = try await URLSession.shared.data(from: invalidURL)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)

        let validURL = try XCTUnwrap(URL(string: "?code=good%2Bcode&state=expected", relativeTo: redirect)?.absoluteURL)
        let (body, validResponse) = try await URLSession.shared.data(from: validURL)
        XCTAssertEqual((validResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("good+code") == true)
        let callbackCode = try await waiting.value
        XCTAssertEqual(callbackCode, "good+code")
        do {
            _ = try await server.waitForCode(timeoutSeconds: 0)
            XCTFail("Expected single-use listener to stay closed")
        } catch {
            XCTAssertEqual(error as? GoogleDriveLoopbackError, .cancelled)
        }
    }

    func testActualLoopbackCancellationClosesPendingWait() async throws {
        let server = GoogleDriveLoopbackServer(expectedState: "expected")
        _ = try await server.start()
        let waiting = Task { try await server.waitForCode(timeoutSeconds: 30) }
        await Task.yield()
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleDriveLoopbackError, .cancelled)
        }
    }

    func testActualLoopbackPreCancelledWaitClosesStartedListener() async throws {
        let server = GoogleDriveLoopbackServer(expectedState: "expected")
        _ = try await server.start()
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await server.waitForCode(timeoutSeconds: 30)
        }

        do {
            _ = try await waiting.value
            XCTFail("Expected normalized pre-cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleDriveLoopbackError, .cancelled)
        }
        do {
            _ = try await server.waitForCode(timeoutSeconds: 0)
            XCTFail("Expected pre-cancellation to leave the listener stopped")
        } catch {
            XCTAssertEqual(error as? GoogleDriveLoopbackError, .cancelled)
        }
    }

    func testSignInUsesPKCEAndPersistsTokenBeforeConnecting() async throws {
        let store = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: nil
        ))
        let browser = CapturingBrowser()
        let loopback = FakeLoopback(code: "code +/한글")
        let random = SequencedRandom(values: [
            Data(repeating: 0x01, count: 32),
            Data(repeating: 0x02, count: 32),
        ])
        TestURLProtocol.handler = { request in
            XCTAssertEqual(
                try Self.requestBody(request),
                "client_id=123.apps.googleusercontent.com&client_secret=client-secret&code=code%20%2B%2F%ED%95%9C%EA%B8%80&code_verifier=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE&grant_type=authorization_code&redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2F"
            )
            return Self.response(
                request: request,
                status: 200,
                body: #"{"access_token":"access","expires_in":3600,"refresh_token":"refresh","scope":"https://www.googleapis.com/auth/drive.file","token_type":"Bearer"}"#
            )
        }
        let authorization = GoogleDriveAuthorization(
            store: store,
            session: makeSession(),
            browser: browser,
            loopbackFactory: { _ in loopback },
            randomBytes: random.bytes,
            now: { Date(timeIntervalSince1970: 10) }
        )
        try authorization.restore()
        try await authorization.signIn()

        XCTAssertTrue(authorization.isConnected)
        XCTAssertEqual(store.value?.tokens?.refreshToken, "refresh")
        let opened = try XCTUnwrap(browser.openedURL)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["state"], GoogleDriveAuthorization.base64URLEncoded(Data(repeating: 0x02, count: 32)))
        XCTAssertEqual(items["scope"], GoogleDriveAuthorization.driveFileScope)
        XCTAssertGreaterThanOrEqual(loopback.cancelCount, 1)
    }

    func testCancellationCleansUpLoopbackAndDoesNotConnect() async throws {
        let store = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: nil
        ))
        let loopback = FakeLoopback(code: nil)
        let authorization = GoogleDriveAuthorization(
            store: store,
            browser: CapturingBrowser(),
            loopbackFactory: { _ in loopback },
            randomBytes: { Data(repeating: 0x03, count: $0) }
        )
        try authorization.restore()
        let task = Task { try await authorization.signIn() }
        while !loopback.isWaiting {
            await Task.yield()
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? GoogleDriveAuthorizationError, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(loopback.cancelCount, 1)
        XCTAssertFalse(authorization.isConnected)
        XCTAssertNil(store.value?.tokens)
    }

    func testCredentialStoreErrorsDoNotPretendConfigurationOrConnectionSucceeded() async throws {
        let failingConfigureStore = MemoryCredentialStore(initial: nil)
        failingConfigureStore.saveError = TestError.keychain
        let configuring = GoogleDriveAuthorization(store: failingConfigureStore)
        XCTAssertThrowsError(try configuring.configure(json: Data("""
        {"installed":{"client_id":"123.apps.googleusercontent.com"}}
        """.utf8)))
        XCTAssertFalse(configuring.isConfigured)

        let failingTokenStore = MemoryCredentialStore(initial: GoogleDriveStoredAuthorization(
            configuration: configuration,
            tokens: nil
        ))
        let loopback = FakeLoopback(code: "code")
        TestURLProtocol.handler = { request in
            Self.response(
                request: request,
                status: 200,
                body: #"{"access_token":"access","expires_in":3600,"refresh_token":"refresh","token_type":"Bearer"}"#
            )
        }
        let signingIn = GoogleDriveAuthorization(
            store: failingTokenStore,
            session: makeSession(),
            browser: CapturingBrowser(),
            loopbackFactory: { _ in loopback },
            randomBytes: { Data(repeating: 0x04, count: $0) }
        )
        try signingIn.restore()
        failingTokenStore.saveError = TestError.keychain
        do {
            try await signingIn.signIn()
            XCTFail("Expected persistence failure")
        } catch {
            XCTAssertEqual(error as? TestError, .keychain)
        }
        XCTAssertFalse(signingIn.isConnected)
    }

    private var configuration: GoogleDriveOAuthConfiguration {
        GoogleDriveOAuthConfiguration(
            clientID: "123.apps.googleusercontent.com",
            clientSecret: "client-secret"
        )
    }

    private var expiredTokens: GoogleDriveOAuthTokens {
        GoogleDriveOAuthTokens(
            accessToken: "access-old",
            refreshToken: "refresh-old",
            expirationDate: Date(timeIntervalSince1970: 0)
        )
    }

    private func callback(_ request: String) -> GoogleDriveLoopbackRequest {
        GoogleDriveLoopbackRequest.parse(header: Data(request.utf8), expectedState: "expected")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeDelayedSession() -> URLSession {
        DelayedURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static func response(
        request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    nonisolated private static func requestBody(_ request: URLRequest) throws -> String {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    throw stream.streamError ?? URLError(.cannotDecodeContentData)
                }
                if count == 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else {
            data = Data()
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return value
    }
}

private enum TestError: Error, Equatable {
    case keychain
}

private final class MemoryCredentialStore: GoogleDriveCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: GoogleDriveStoredAuthorization?
    var saveError: Error?
    var loadError: Error?

    init(initial: GoogleDriveStoredAuthorization?) {
        storedValue = initial
    }

    var value: GoogleDriveStoredAuthorization? {
        lock.withLock { storedValue }
    }

    func load() throws -> GoogleDriveStoredAuthorization? {
        try lock.withLock {
            if let loadError { throw loadError }
            return storedValue
        }
    }

    func save(_ authorization: GoogleDriveStoredAuthorization) throws {
        try lock.withLock {
            if let saveError { throw saveError }
            storedValue = authorization
        }
    }
}

@MainActor
private final class CapturingBrowser: GoogleDriveBrowserOpening, @unchecked Sendable {
    private(set) var openedURL: URL?

    func open(_ url: URL) -> Bool {
        openedURL = url
        return true
    }
}

private final class SequencedRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(values: [Data]) {
        self.values = values
    }

    func bytes(count: Int) throws -> Data {
        lock.withLock {
            let value = values.removeFirst()
            XCTAssertEqual(value.count, count)
            return value
        }
    }
}

private final class FakeLoopback: GoogleDriveLoopbackServing, @unchecked Sendable {
    private let lock = NSLock()
    private let code: String?
    private var continuation: CheckedContinuation<String, Error>?
    private var cancellations = 0
    private var waiting = false

    init(code: String?) {
        self.code = code
    }

    var cancelCount: Int { lock.withLock { cancellations } }
    var isWaiting: Bool { lock.withLock { waiting } }

    func start() async throws -> URL {
        URL(string: "http://127.0.0.1:54321/")!
    }

    func waitForCode(timeoutSeconds: TimeInterval) async throws -> String {
        if let code { return code }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    waiting = true
                    self.continuation = continuation
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let suspended: CheckedContinuation<String, Error>? = lock.withLock {
            cancellations += 1
            waiting = false
            let suspended = continuation
            continuation = nil
            return suspended
        }
        suspended?.resume(throwing: GoogleDriveLoopbackError.cancelled)
    }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class DelayedURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: DelayedURLProtocol?

    static var hasPendingRequest: Bool {
        lock.withLock { pending != nil }
    }

    static func reset() {
        lock.withLock { pending = nil }
    }

    static func respond(status: Int, body: String) {
        let target = lock.withLock { () -> DelayedURLProtocol? in
            let value = pending
            pending = nil
            return value
        }
        guard let target, let url = target.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else { return }
        target.client?.urlProtocol(target, didReceive: response, cacheStoragePolicy: .notAllowed)
        target.client?.urlProtocol(target, didLoad: Data(body.utf8))
        target.client?.urlProtocolDidFinishLoading(target)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.pending = self }
    }

    override func stopLoading() {
        Self.lock.withLock {
            if Self.pending === self { Self.pending = nil }
        }
    }
}
