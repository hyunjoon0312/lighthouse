import Foundation
import XCTest
@testable import LighthouseCore

@MainActor
final class GoogleDriveClientTests: XCTestCase {
    private func client(responses: [StubResponse]) -> (GoogleDriveClient, StubState) {
        let state = StubState(responses: responses)
        let identifier = UUID().uuidString
        DriveURLProtocol.register(state, identifier: identifier)
        addTeardownBlock { DriveURLProtocol.unregister(identifier: identifier) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriveURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Lighthouse-Test": identifier]
        return (GoogleDriveClient(session: URLSession(configuration: configuration)), state)
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAccountFoldersAndCreateFolderUseExactRoutesAndBodies() async throws {
        let (client, state) = client(responses: [
            .json(200, ["user": ["displayName": "빛", "emailAddress": "light@example.com"]]),
            .json(200, ["nextPageToken": "next", "files": [["id": "1", "name": "가"]]]),
            .json(200, ["files": [["id": "2", "name": "나", "webViewLink": "https://drive.google.com/a"]]]),
            .json(200, ["id": "folder", "name": "제주 사진"])
        ])

        let account = try await client.account(accessToken: "token")
        let folders = try await client.folders(accessToken: "token")
        let created = try await client.createFolder(name: "  제주 사진  ", accessToken: "token")
        XCTAssertEqual(account, GoogleDriveAccount(displayName: "빛", emailAddress: "light@example.com"))
        XCTAssertEqual(folders.map(\.id), ["1", "2"])
        XCTAssertEqual(created.name, "제주 사진")

        let requests = state.recordedRequests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].url.path, "/drive/v3/about")
        XCTAssertEqual(requests[0].query["fields"], "user(displayName,emailAddress)")
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer token")

        XCTAssertEqual(requests[1].url.path, "/drive/v3/files")
        XCTAssertEqual(requests[1].query["q"],
                       "mimeType = 'application/vnd.google-apps.folder' and trashed = false and appProperties has { key='lighthouse' and value='uploads' }")
        XCTAssertEqual(requests[1].query["fields"], "nextPageToken,files(id,name,webViewLink)")
        XCTAssertEqual(requests[1].query["orderBy"], "name")
        XCTAssertNil(requests[1].query["pageToken"])
        XCTAssertEqual(requests[2].query["pageToken"], "next")

        XCTAssertEqual(requests[3].method, "POST")
        XCTAssertEqual(requests[3].query["fields"], "id,name,webViewLink")
        let folderBody = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[3].body) as? [String: Any])
        XCTAssertEqual(folderBody["name"] as? String, "제주 사진")
        XCTAssertEqual(folderBody["mimeType"] as? String, "application/vnd.google-apps.folder")
        XCTAssertEqual((folderBody["appProperties"] as? [String: String])?["lighthouse"], "uploads")
    }

    func testUploadUsesGeneratedIDResumableSessionAndFileBody() async throws {
        let original = Data((0..<64_000).map { UInt8($0 % 251) })
        let fileURL = try temporaryFile(original)
        let location = "https://www.googleapis.com/upload/drive/v3/files?upload_id=session-1"
        let (client, state) = client(responses: [
            .json(200, ["ids": ["generated-id"]]),
            .response(200, headers: ["Location": location]),
            .json(201, ["id": "generated-id", "name": "제주 원본.RW2", "webViewLink": "https://drive.google.com/file"])
        ])

        let uploaded = try await client.upload(fileURL: fileURL, name: "제주 원본.RW2",
                                               mimeType: "image/x-panasonic-rw2", parentID: "부모-ID",
                                               accessToken: "secret-token")
        XCTAssertEqual(uploaded.id, "generated-id")
        XCTAssertEqual(try Data(contentsOf: fileURL), original)

        let requests = state.recordedRequests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "PUT"])
        XCTAssertEqual(requests[0].url.path, "/drive/v3/files/generateIds")
        XCTAssertEqual(requests[0].query, ["count": "1", "space": "drive", "type": "files"])
        XCTAssertEqual(requests[1].url.path, "/upload/drive/v3/files")
        XCTAssertEqual(requests[1].query["uploadType"], "resumable")
        XCTAssertEqual(requests[1].headers["X-Upload-Content-Type"], "image/x-panasonic-rw2")
        XCTAssertEqual(requests[1].headers["X-Upload-Content-Length"], String(original.count))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
        XCTAssertEqual(metadata["id"] as? String, "generated-id")
        XCTAssertEqual(metadata["name"] as? String, "제주 원본.RW2")
        XCTAssertEqual(metadata["parents"] as? [String], ["부모-ID"])
        XCTAssertEqual(requests[2].url.absoluteString, location)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(requests[2].headers["Content-Type"], "image/x-panasonic-rw2")
        XCTAssertEqual(requests[2].body, original)
    }

    func testRejectsUntrustedResumableLocationsBeforePUT() async throws {
        let fileURL = try temporaryFile(Data([1, 2, 3]))
        let locations = [
            "http://www.googleapis.com/upload/drive/v3/files?upload_id=x",
            "https://evil.example/upload/drive/v3/files?upload_id=x",
            "https://user@www.googleapis.com/upload/drive/v3/files?upload_id=x",
            "https://www.googleapis.com:444/upload/drive/v3/files?upload_id=x",
            "https://www.googleapis.com/upload/drive/v3/files/extra?upload_id=x",
            "https://www.googleapis.com/upload/drive/v3/files?upload_id=x#fragment"
        ]
        for location in locations {
            let (client, state) = client(responses: [
                .json(200, ["ids": ["generated-id"]]),
                .response(200, headers: ["Location": location])
            ])
            do {
                _ = try await client.upload(fileURL: fileURL, name: "photo.jpg", mimeType: "image/jpeg",
                                            parentID: "folder", accessToken: "token")
                XCTFail("거부해야 하는 업로드 주소: \(location)")
            } catch let error as GoogleDriveError {
                guard case .invalidUploadLocation = error else {
                    return XCTFail("예상하지 못한 오류: \(error)")
                }
            }
            XCTAssertEqual(state.recordedRequests.count, 2)
        }
    }

    func testHTTPFailuresDoNotExposeResponseBodies() async throws {
        let (accountClient, _) = client(responses: [.json(401, ["error": "token detail"] )])
        do {
            _ = try await accountClient.account(accessToken: "token")
            XCTFail("401을 성공으로 처리했습니다")
        } catch let error as GoogleDriveError {
            guard case .httpStatus(401) = error else { return XCTFail("예상하지 못한 오류: \(error)") }
            XCTAssertFalse(error.localizedDescription.contains("token detail"))
        }

        let (quotaClient, _) = client(responses: [.json(403, ["error": "quota detail"] )])
        do {
            _ = try await quotaClient.createFolder(name: "Lighthouse", accessToken: "token")
            XCTFail("quota 오류를 성공으로 처리했습니다")
        } catch let error as GoogleDriveError {
            guard case .httpStatus(403) = error else { return XCTFail("예상하지 못한 오류: \(error)") }
            XCTAssertFalse(error.localizedDescription.contains("quota detail"))
        }

        let (invalidClient, _) = client(responses: [
            .response(200, headers: ["Content-Type": "application/json"], data: Data("not json".utf8))
        ])
        do {
            _ = try await invalidClient.account(accessToken: "token")
            XCTFail("잘못된 JSON을 성공으로 처리했습니다")
        } catch let error as GoogleDriveError {
            guard case .invalidResponse = error else { return XCTFail("예상하지 못한 오류: \(error)") }
        }
    }

    func testLostUploadResponseResolvesByGeneratedIDWithoutCreatingAgain() async throws {
        let fileURL = try temporaryFile(Data([4, 5, 6]))
        let (client, state) = client(responses: [
            .json(200, ["ids": ["known-id"]]),
            .response(200, headers: [
                "Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=lost"
            ]),
            .failure(URLError(.networkConnectionLost)),
            .json(200, ["id": "known-id", "name": "photo.jpg", "size": "3"])
        ])

        let file = try await client.upload(fileURL: fileURL, name: "photo.jpg", mimeType: "image/jpeg",
                                           parentID: "folder", accessToken: "token")
        XCTAssertEqual(file.id, "known-id")
        let requests = state.recordedRequests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "PUT", "GET"])
        XCTAssertEqual(requests.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(requests[3].url.path, "/drive/v3/files/known-id")
        XCTAssertEqual(requests[3].query["fields"], "id,name,webViewLink,size")
    }

    func testMalformedSuccessfulUploadRecoversOnlyMatchingIDAndSize() async throws {
        let fileURL = try temporaryFile(Data([10, 11, 12]))
        let (client, state) = client(responses: [
            .json(200, ["ids": ["known-id"]]),
            .response(200, headers: [
                "Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=malformed"
            ]),
            .response(200, headers: ["Content-Type": "application/json"], data: Data("not json".utf8)),
            .json(200, ["id": "known-id", "name": "photo.jpg", "size": "3"])
        ])

        let file = try await client.upload(fileURL: fileURL, name: "photo.jpg", mimeType: "image/jpeg",
                                           parentID: "folder", accessToken: "token")
        XCTAssertEqual(file, GoogleDriveFile(id: "known-id", name: "photo.jpg"))
        XCTAssertEqual(state.recordedRequests.map(\.method), ["GET", "POST", "PUT", "GET"])
        XCTAssertEqual(state.recordedRequests.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(state.recordedRequests.filter { $0.method == "PUT" }.count, 1)
    }

    func testMalformedSuccessfulUploadRejectsWrongRecoveryIDOrSize() async throws {
        let fileURL = try temporaryFile(Data([13, 14, 15]))
        let recoveredFiles: [[String: Any]] = [
            ["id": "other-id", "name": "photo.jpg", "size": "3"],
            ["id": "known-id", "name": "photo.jpg", "size": "4"]
        ]
        for recovered in recoveredFiles {
            let (client, state) = client(responses: [
                .json(200, ["ids": ["known-id"]]),
                .response(200, headers: [
                    "Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=malformed"
                ]),
                .response(201, headers: ["Content-Type": "application/json"], data: Data("{}".utf8)),
                .json(200, recovered)
            ])
            do {
                _ = try await client.upload(fileURL: fileURL, name: "photo.jpg", mimeType: "image/jpeg",
                                            parentID: "folder", accessToken: "token")
                XCTFail("일치하지 않는 복구 메타데이터를 성공으로 처리했습니다")
            } catch let error as GoogleDriveError {
                guard case .uploadCompletionUnknown = error else {
                    return XCTFail("예상하지 못한 오류: \(error)")
                }
            }
            XCTAssertEqual(state.recordedRequests.map(\.method), ["GET", "POST", "PUT", "GET"])
        }
    }

    func testUnresolvedLostUploadReportsUncertainCompletion() async throws {
        let fileURL = try temporaryFile(Data([7, 8, 9]))
        let (client, state) = client(responses: [
            .json(200, ["ids": ["known-id"]]),
            .response(200, headers: [
                "Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=lost"
            ]),
            .response(503),
            .json(404, ["error": "not found"])
        ])
        do {
            _ = try await client.upload(fileURL: fileURL, name: "photo.jpg", mimeType: "image/jpeg",
                                        parentID: "folder", accessToken: "token")
            XCTFail("불확실한 완료를 성공으로 처리했습니다")
        } catch let error as GoogleDriveError {
            guard case .uploadCompletionUnknown = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("완료 여부를 확인"))
        }
        XCTAssertEqual(state.recordedRequests.map(\.method), ["GET", "POST", "PUT", "GET"])
    }

    func testCancellationStopsPendingRequest() async throws {
        let (client, state) = client(responses: [.delayed(5, status: 200, body: ["user": [
            "displayName": "빛", "emailAddress": "light@example.com"
        ]])])
        let task = Task { try await client.account(accessToken: "token") }
        for _ in 0..<200 where state.recordedRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(state.recordedRequests.isEmpty)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소된 요청이 성공했습니다")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(state.recordedRequests.count, 1)
    }

    func testMissingAndEmptyFilesSendNoRequests() async throws {
        let empty = try temporaryFile(Data())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (client, state) = client(responses: [])
        for url in [empty, missing] {
            do {
                _ = try await client.upload(fileURL: url, name: "photo.jpg", mimeType: "image/jpeg",
                                            parentID: "folder", accessToken: "token")
                XCTFail("잘못된 파일을 업로드했습니다")
            } catch let error as GoogleDriveError {
                guard case .invalidFile = error else { return XCTFail("예상하지 못한 오류: \(error)") }
            }
        }
        XCTAssertEqual(state.recordedRequests.count, 0)
    }
}

private struct RecordedRequest: @unchecked Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data

    var query: [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }
}

private enum StubResponse: @unchecked Sendable {
    case response(Int, headers: [String: String] = [:], data: Data = Data())
    case failure(Error)
    case delayed(TimeInterval, status: Int, body: [String: Any])

    static func json(_ status: Int, _ body: [String: Any]) -> StubResponse {
        .response(status, headers: ["Content-Type": "application/json"],
                  data: try! JSONSerialization.data(withJSONObject: body))
    }
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StubResponse]
    private var requests: [RecordedRequest] = []

    init(responses: [StubResponse]) {
        self.responses = responses
    }

    var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func consume(_ request: URLRequest) throws -> StubResponse {
        let recorded = try RecordedRequest(method: request.httpMethod ?? "GET", url: request.url!,
                                           headers: request.allHTTPHeaderFields ?? [:],
                                           body: Self.bodyData(request))
        lock.lock()
        defer { lock.unlock() }
        requests.append(recorded)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class DriveURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var states: [String: StubState] = [:]
    private static let statesLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false

    static func register(_ state: StubState, identifier: String) {
        statesLock.lock()
        defer { statesLock.unlock() }
        states[identifier] = state
    }

    static func unregister(identifier: String) {
        statesLock.lock()
        defer { statesLock.unlock() }
        states.removeValue(forKey: identifier)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let identifier = request.value(forHTTPHeaderField: "X-Lighthouse-Test"),
              let state = Self.state(identifier: identifier) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            switch try state.consume(request) {
            case .response(let status, let headers, let data):
                deliver(status: status, headers: headers, data: data)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .delayed(let delay, let status, let body):
                let data = try JSONSerialization.data(withJSONObject: body)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                    deliver(status: status, headers: ["Content-Type": "application/json"], data: data)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func deliver(status: Int, headers: [String: String], data: Data) {
        stateLock.lock()
        let shouldStop = stopped
        stateLock.unlock()
        guard !shouldStop, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func state(identifier: String) -> StubState? {
        statesLock.lock()
        defer { statesLock.unlock() }
        return states[identifier]
    }
}
