import Foundation

public actor GoogleDriveClient: GoogleDriveServicing {
    private static let apiRoot = URL(string: "https://www.googleapis.com")!
    private let session: URLSession
    private let redirectDelegate: NoRedirectDelegate?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let delegate = NoRedirectDelegate()
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            redirectDelegate = delegate
        }
    }

    public func account(accessToken: String) async throws -> GoogleDriveAccount {
        let url = try Self.apiURL(path: "/drive/v3/about", queryItems: [
            URLQueryItem(name: "fields", value: "user(displayName,emailAddress)")
        ])
        let (data, response) = try await data(for: authorizedRequest(url: url, accessToken: accessToken))
        try Self.requireSuccess(response)
        do {
            return try decoder.decode(AboutResponse.self, from: data).user
        } catch {
            throw GoogleDriveError.invalidResponse
        }
    }

    public func folders(accessToken: String) async throws -> [GoogleDriveFile] {
        var files: [GoogleDriveFile] = []
        var pageToken: String?
        var seenPageTokens: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var queryItems = [
                URLQueryItem(name: "q", value: "mimeType = 'application/vnd.google-apps.folder' and trashed = false and appProperties has { key='lighthouse' and value='uploads' }"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,webViewLink)"),
                URLQueryItem(name: "orderBy", value: "name")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let url = try Self.apiURL(path: "/drive/v3/files", queryItems: queryItems)
            let (data, response) = try await data(for: authorizedRequest(url: url, accessToken: accessToken))
            try Self.requireSuccess(response)
            let page: FileListResponse
            do {
                page = try decoder.decode(FileListResponse.self, from: data)
            } catch {
                throw GoogleDriveError.invalidResponse
            }
            files.append(contentsOf: page.files)
            if let next = page.nextPageToken {
                guard !next.isEmpty, seenPageTokens.insert(next).inserted else {
                    throw GoogleDriveError.invalidResponse
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    public func createFolder(name: String, accessToken: String) async throws -> GoogleDriveFile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw GoogleDriveError.invalidFolderName }
        let url = try Self.apiURL(path: "/drive/v3/files", queryItems: [
            URLQueryItem(name: "fields", value: "id,name,webViewLink")
        ])
        let body = FolderMetadata(name: trimmed,
                                  mimeType: "application/vnd.google-apps.folder",
                                  appProperties: ["lighthouse": "uploads"])
        var request = authorizedRequest(url: url, accessToken: accessToken, method: "POST")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await data(for: request)
        try Self.requireSuccess(response)
        return try decodeFile(data)
    }

    public func upload(fileURL: URL, name: String, mimeType: String, parentID: String,
                       accessToken: String) async throws -> GoogleDriveFile {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw GoogleDriveError.invalidFile
        }
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            throw GoogleDriveError.invalidFile
        }

        let fileID = try await generateFileID(accessToken: accessToken)
        try Task.checkCancellation()
        let sessionURL = try await createUploadSession(fileID: fileID, name: name, mimeType: mimeType,
                                                       parentID: parentID, fileSize: fileSize,
                                                       accessToken: accessToken)
        try Task.checkCancellation()
        var request = authorizedRequest(url: sessionURL, accessToken: accessToken, method: "PUT")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let uploadResult: (Data, URLResponse)
        do {
            uploadResult = try await session.upload(for: request, fromFile: fileURL)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw GoogleDriveError.cancelled
            }
            if let completed = try await completedFile(id: fileID, expectedSize: fileSize,
                                                       accessToken: accessToken) {
                return completed
            }
            throw GoogleDriveError.uploadCompletionUnknown
        }

        guard let response = uploadResult.1 as? HTTPURLResponse else {
            if let completed = try await completedFile(id: fileID, expectedSize: fileSize,
                                                       accessToken: accessToken) {
                return completed
            }
            throw GoogleDriveError.uploadCompletionUnknown
        }
        if response.statusCode == 200 || response.statusCode == 201 {
            do {
                return try decodeFile(uploadResult.0)
            } catch {
                if let completed = try await completedFile(id: fileID, expectedSize: fileSize,
                                                           accessToken: accessToken) {
                    return completed
                }
                throw GoogleDriveError.uploadCompletionUnknown
            }
        }
        if response.statusCode >= 500 {
            if let completed = try await completedFile(id: fileID, expectedSize: fileSize,
                                                       accessToken: accessToken) {
                return completed
            }
            throw GoogleDriveError.uploadCompletionUnknown
        }
        throw GoogleDriveError.httpStatus(response.statusCode)
    }

    private func generateFileID(accessToken: String) async throws -> String {
        let url = try Self.apiURL(path: "/drive/v3/files/generateIds", queryItems: [
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "space", value: "drive"),
            URLQueryItem(name: "type", value: "files")
        ])
        let (data, response) = try await data(for: authorizedRequest(url: url, accessToken: accessToken))
        try Self.requireSuccess(response)
        do {
            let result = try decoder.decode(GeneratedIDs.self, from: data)
            guard result.ids.count == 1, let id = result.ids.first, Self.validFileID(id) else {
                throw GoogleDriveError.invalidResponse
            }
            return id
        } catch let error as GoogleDriveError {
            throw error
        } catch {
            throw GoogleDriveError.invalidResponse
        }
    }

    private func createUploadSession(fileID: String, name: String, mimeType: String, parentID: String,
                                     fileSize: Int, accessToken: String) async throws -> URL {
        let url = try Self.apiURL(path: "/upload/drive/v3/files", queryItems: [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id,name,webViewLink")
        ])
        var request = authorizedRequest(url: url, accessToken: accessToken, method: "POST")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try encoder.encode(UploadMetadata(id: fileID, name: name, parents: [parentID]))
        let (_, response) = try await data(for: request)
        try Self.requireSuccess(response)
        guard let value = response.value(forHTTPHeaderField: "Location"),
              let location = URL(string: value), Self.validUploadLocation(location) else {
            throw GoogleDriveError.invalidUploadLocation
        }
        return location
    }

    private func completedFile(id: String, expectedSize: Int,
                               accessToken: String) async throws -> GoogleDriveFile? {
        try Task.checkCancellation()
        guard Self.validFileID(id) else { return nil }
        let path = "/drive/v3/files/" + id
        let url: URL
        do {
            url = try Self.apiURL(path: path, queryItems: [
                URLQueryItem(name: "fields", value: "id,name,webViewLink,size")
            ])
        } catch {
            return nil
        }
        do {
            let (data, response) = try await self.data(for: authorizedRequest(url: url, accessToken: accessToken))
            guard response.statusCode == 200 else { return nil }
            guard let recovered = try? decoder.decode(RecoveredFile.self, from: data),
                  recovered.id == id, recovered.size == Int64(expectedSize) else { return nil }
            return GoogleDriveFile(id: recovered.id, name: recovered.name, webViewLink: recovered.webViewLink)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let driveError = error as? GoogleDriveError, case .cancelled = driveError { throw driveError }
            return nil
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw GoogleDriveError.invalidResponse }
            return (data, http)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw GoogleDriveError.cancelled
            }
            throw error
        }
    }

    private func decodeFile(_ data: Data) throws -> GoogleDriveFile {
        do {
            return try decoder.decode(GoogleDriveFile.self, from: data)
        } catch {
            throw GoogleDriveError.invalidResponse
        }
    }

    private func authorizedRequest(url: URL, accessToken: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func requireSuccess(_ response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw GoogleDriveError.httpStatus(response.statusCode)
        }
    }

    private static func apiURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems
        guard let url = components?.url else { throw GoogleDriveError.invalidResponse }
        return url
    }

    private static func validUploadLocation(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" &&
            components.host?.lowercased() == "www.googleapis.com" &&
            (components.port == nil || components.port == 443) &&
            components.user == nil && components.password == nil && components.fragment == nil &&
            components.percentEncodedPath == "/upload/drive/v3/files"
    }

    private static func validFileID(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return !id.isEmpty && id.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct AboutResponse: Decodable {
    let user: GoogleDriveAccount
}

private struct FileListResponse: Decodable {
    let nextPageToken: String?
    let files: [GoogleDriveFile]
}

private struct GeneratedIDs: Decodable {
    let ids: [String]
}

private struct FolderMetadata: Encodable {
    let name: String
    let mimeType: String
    let appProperties: [String: String]
}

private struct UploadMetadata: Encodable {
    let id: String
    let name: String
    let parents: [String]
}

private struct RecoveredFile: Decodable {
    let id: String
    let name: String
    let webViewLink: String?
    let size: Int64

    private enum CodingKeys: String, CodingKey {
        case id, name, webViewLink, size
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        webViewLink = try values.decodeIfPresent(String.self, forKey: .webViewLink)
        if let number = try? values.decode(Int64.self, forKey: .size) {
            size = number
        } else {
            let text = try values.decode(String.self, forKey: .size)
            guard let number = Int64(text) else {
                throw DecodingError.dataCorruptedError(forKey: .size, in: values,
                                                       debugDescription: "Invalid file size")
            }
            size = number
        }
    }
}
