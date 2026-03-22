import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the ClaudeRelay admin API (127.0.0.1:adminPort).
public final class AdminClient {
    public let baseURL: URL
    private let session: URLSession

    public init(port: UInt16 = 9100) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = URLSession.shared
    }

    /// Build a URL from the base and a path that may contain query strings.
    /// Unlike `appendingPathComponent`, this preserves `?` and `&` in paths.
    private func buildURL(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path)!
    }

    /// GET request, returns decoded JSON.
    public func get<T: Decodable>(_ path: String) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    /// POST request with optional body, returns decoded JSON.
    public func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body = body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request)
    }

    /// PUT request with body, returns decoded JSON.
    public func put<T: Decodable>(_ path: String, body: any Encodable) async throws -> T {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    /// DELETE request.
    public func delete(_ path: String) async throws {
        let url = buildURL(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await performRaw(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AdminClientError.serviceNotRunning
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AdminClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Check if service is running (GET /health, handle connection refused).
    public func isServiceRunning() async -> Bool {
        let url = buildURL("/health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await performRaw(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await performRaw(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AdminClientError.serviceNotRunning
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AdminClientError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AdminClientError.decodingError(error)
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost
            || error.code == .networkConnectionLost
            || error.code == .timedOut
            || error.code == .cannotFindHost {
            throw AdminClientError.serviceNotRunning
        }
    }
}

// MARK: - Error

public enum AdminClientError: Error, LocalizedError {
    case serviceNotRunning
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)

    public var errorDescription: String? {
        switch self {
        case .serviceNotRunning:
            return "Service is not running"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let err):
            return "Failed to decode response: \(err)"
        }
    }
}

// MARK: - AnyEncodable helper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self._encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
