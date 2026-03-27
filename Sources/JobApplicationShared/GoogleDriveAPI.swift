import Foundation
import CryptoKit
import os.log

private let syncLog = Logger(subsystem: "com.zsparks.JobApplicationWizard", category: "GoogleDriveAPI")

// MARK: - Shared Models

public struct DriveFile: Codable, Sendable {
    public let id: String
    public let name: String
    public var modifiedTime: String?
    public var size: String?
    public var version: String?

    public init(id: String, name: String, modifiedTime: String? = nil, size: String? = nil, version: String? = nil) {
        self.id = id
        self.name = name
        self.modifiedTime = modifiedTime
        self.size = size
        self.version = version
    }
}

public struct DriveFileListResponse: Codable, Sendable {
    public let files: [DriveFile]
    public let nextPageToken: String?
}

public struct TokenResponse: Codable, Sendable {
    public let access_token: String
    public let expires_in: Int
    public let refresh_token: String?
    public let token_type: String
}

// MARK: - PKCE Helpers

public func generateCodeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

public func generateCodeChallenge(from verifier: String) -> String {
    let data = Data(verifier.utf8)
    let hash = SHA256.hash(data: data)
    return Data(hash).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - URL Encoding

public let formURLAllowed: CharacterSet = {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return allowed
}()

public func urlEncode(_ string: String) -> String {
    string.addingPercentEncoding(withAllowedCharacters: formURLAllowed) ?? string
}

// MARK: - Google Drive API

/// Platform-agnostic Google Drive API operations.
/// Each method takes a `tokenProvider` closure that returns a valid access token.
public enum GoogleDriveAPI {
    public static let driveFilesURL = "https://www.googleapis.com/drive/v3/files"
    public static let driveUploadURL = "https://www.googleapis.com/upload/drive/v3/files"

    public typealias TokenProvider = @Sendable () async throws -> String

    // MARK: - HTTP Helpers

    private static let syncSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public static func checkedData(for request: URLRequest) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        syncLog.debug("[DriveAPI] \(method) \(url)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await syncSession.data(for: request)
        } catch {
            syncLog.error("[DriveAPI] \(method) \(url) network error: \(error.localizedDescription)")
            throw SyncStorageError.networkError(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            syncLog.error("[DriveAPI] \(method) \(url) bad server response")
            throw SyncStorageError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            syncLog.error("[DriveAPI] \(method) \(url) HTTP \(httpResponse.statusCode): \(body)")
            throw SyncStorageError.storageError("HTTP \(httpResponse.statusCode): \(body)")
        }
        syncLog.debug("[DriveAPI] \(method) \(url) -> \(httpResponse.statusCode), \(data.count) bytes")
        return data
    }

    // MARK: - File Operations

    /// List files in the appDataFolder matching a query, with pagination.
    public static func listFiles(query: String? = nil, tokenProvider: TokenProvider) async throws -> [DriveFile] {
        syncLog.debug("[DriveAPI] listFiles query=\(query ?? "nil")")
        var allFiles: [DriveFile] = []
        var pageToken: String? = nil

        repeat {
            let token = try await tokenProvider()
            var components = URLComponents(string: driveFilesURL)!
            var queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime,size,version)"),
                URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]
            if let query { queryItems.append(URLQueryItem(name: "q", value: query)) }
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let data = try await checkedData(for: request)
            let response = try JSONDecoder().decode(DriveFileListResponse.self, from: data)
            allFiles.append(contentsOf: response.files)
            pageToken = response.nextPageToken
        } while pageToken != nil

        syncLog.debug("[DriveAPI] listFiles found \(allFiles.count) files")
        return allFiles
    }

    /// Upload a file to appDataFolder (or update an existing file).
    public static func uploadFile(name: String, data: Data, existingFileId: String? = nil, tokenProvider: TokenProvider) async throws -> String {
        syncLog.debug("[DriveAPI] uploadFile name=\(name), size=\(data.count), existingId=\(existingFileId ?? "nil")")
        let token = try await tokenProvider()
        let boundary = UUID().uuidString
        var body = Data()

        let metadata: [String: Any] = existingFileId != nil
            ? ["name": name]
            : ["name": name, "parents": ["appDataFolder"]]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let urlString = existingFileId != nil
            ? "\(driveUploadURL)/\(existingFileId!)?uploadType=multipart"
            : "\(driveUploadURL)?uploadType=multipart"

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = existingFileId != nil ? "PATCH" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let responseData = try await checkedData(for: request)
        let file = try JSONDecoder().decode(DriveFile.self, from: responseData)
        syncLog.debug("[DriveAPI] uploadFile success, id=\(file.id)")
        return file.id
    }

    /// Upload a file with conditional version check (for optimistic concurrency).
    /// If `expectedVersion` is provided, verifies the remote file's version matches before uploading.
    /// Throws `SyncStorageError.conflict` on version mismatch.
    public static func uploadFileConditional(
        name: String,
        data: Data,
        existingFileId: String?,
        expectedVersion: String?,
        tokenProvider: TokenProvider
    ) async throws -> DriveFile {
        syncLog.debug("[DriveAPI] uploadFileConditional name=\(name), size=\(data.count), existingId=\(existingFileId ?? "nil"), expectedVersion=\(expectedVersion ?? "nil")")

        // If we have an existing file and an expected version, verify it hasn't changed
        if let fileId = existingFileId, let expected = expectedVersion {
            let token = try await tokenProvider()
            var components = URLComponents(string: "\(driveFilesURL)/\(fileId)")!
            components.queryItems = [URLQueryItem(name: "fields", value: "id,name,version")]
            var checkRequest = URLRequest(url: components.url!)
            checkRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let checkData = try await checkedData(for: checkRequest)
            let currentFile = try JSONDecoder().decode(DriveFile.self, from: checkData)
            if let currentVersion = currentFile.version, currentVersion != expected {
                syncLog.warning("[DriveAPI] uploadFileConditional conflict: expected=\(expected), actual=\(currentVersion)")
                throw SyncStorageError.conflict
            }
        }

        // Perform the upload
        let token = try await tokenProvider()
        let boundary = UUID().uuidString
        var body = Data()

        let metadata: [String: Any] = existingFileId != nil
            ? ["name": name]
            : ["name": name, "parents": ["appDataFolder"]]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let urlString = existingFileId != nil
            ? "\(driveUploadURL)/\(existingFileId!)?uploadType=multipart&fields=id,name,modifiedTime,size,version"
            : "\(driveUploadURL)?uploadType=multipart&fields=id,name,modifiedTime,size,version"

        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = existingFileId != nil ? "PATCH" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let responseData = try await checkedData(for: request)
        let file = try JSONDecoder().decode(DriveFile.self, from: responseData)

        syncLog.debug("[DriveAPI] uploadFileConditional success, id=\(file.id), version=\(file.version ?? "nil")")
        return file
    }

    /// Download a file's content by ID.
    public static func downloadFile(fileId: String, tokenProvider: TokenProvider) async throws -> Data {
        syncLog.debug("[DriveAPI] downloadFile id=\(fileId)")
        let token = try await tokenProvider()
        var components = URLComponents(string: "\(driveFilesURL)/\(fileId)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await checkedData(for: request)
        syncLog.debug("[DriveAPI] downloadFile id=\(fileId) -> \(data.count) bytes")
        return data
    }

    /// Delete a file by ID.
    public static func deleteFile(fileId: String, tokenProvider: TokenProvider) async throws {
        syncLog.debug("[DriveAPI] deleteFile id=\(fileId)")
        let token = try await tokenProvider()
        var request = URLRequest(url: URL(string: "\(driveFilesURL)/\(fileId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await checkedData(for: request)
        syncLog.debug("[DriveAPI] deleteFile id=\(fileId) success")
    }

}
