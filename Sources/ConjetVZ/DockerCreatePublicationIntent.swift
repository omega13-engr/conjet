import ConjetCore
import Foundation

public struct DockerCreatePublicationIntent: Equatable, Sendable {
    public var requestPath: String
    public var containerName: String?
    public var ports: Set<DockerPublishedPort>

    public init(requestPath: String, containerName: String?, ports: Set<DockerPublishedPort>) {
        self.requestPath = requestPath
        self.containerName = containerName
        self.ports = ports
    }
}

public struct DockerCreatePublicationResolution: Equatable, Sendable {
    public var intent: DockerCreatePublicationIntent
    public var containerID: String

    public init(intent: DockerCreatePublicationIntent, containerID: String) {
        self.intent = intent
        self.containerID = containerID
    }
}

public struct DockerContainerStartRequest: Equatable, Sendable {
    public var requestPath: String
    public var containerID: String

    public init(requestPath: String, containerID: String) {
        self.requestPath = requestPath
        self.containerID = containerID
    }
}

public struct DockerServiceMemorySlice: Equatable, Sendable {
    public var serviceKey: String
    public var cgroupParent: String
    public var composeProject: String?
    public var composeService: String?
    public var containerName: String?

    public init(
        serviceKey: String,
        cgroupParent: String,
        composeProject: String? = nil,
        composeService: String? = nil,
        containerName: String? = nil
    ) {
        self.serviceKey = serviceKey
        self.cgroupParent = cgroupParent
        self.composeProject = composeProject
        self.composeService = composeService
        self.containerName = containerName
    }
}

public struct DockerServiceMemorySliceActivity: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case created
        case started
        case stopped
        case removed
    }

    public var kind: Kind
    public var containerID: String
    public var slice: DockerServiceMemorySlice?

    public init(kind: Kind, containerID: String, slice: DockerServiceMemorySlice? = nil) {
        self.kind = kind
        self.containerID = containerID
        self.slice = slice
    }
}

struct DockerCreateRequestParser {
    private static let headerDelimiter = Data([13, 10, 13, 10])

    static func intent(from data: Data) -> DockerCreatePublicationIntent? {
        guard let request = parseRequest(data),
              request.isContainerCreate,
              request.bodyIsComplete,
              let body = request.decodedBody,
              !body.isEmpty,
              let portBindings = try? JSONDecoder().decode(DockerCreatePortBindingsEnvelope.self, from: body).hostConfig?.portBindings else {
            return nil
        }

        var ports = Set<DockerPublishedPort>()
        for (containerPortKey, bindings) in portBindings {
            let keyParts = containerPortKey.split(separator: "/", maxSplits: 1).map(String.init)
            guard keyParts.count == 2,
                  let containerPort = Int(keyParts[0]),
                  let proto = ConjetPortProtocol(rawValue: keyParts[1]) else {
                continue
            }
            for binding in bindings {
                guard let hostPortText = binding.hostPort,
                      let hostPort = Int(hostPortText),
                      hostPort > 0,
                      hostPort <= 65_535 else {
                    continue
                }
                ports.insert(DockerPublishedPort(
                    hostIP: binding.hostIP,
                    hostPort: hostPort,
                    containerPort: containerPort,
                    protocol: proto,
                    containerName: request.containerName
                ))
            }
        }

        guard !ports.isEmpty else { return nil }
        return DockerCreatePublicationIntent(
            requestPath: request.path,
            containerName: request.containerName,
            ports: ports
        )
    }

    static func additionalBodyBytesNeeded(in data: Data) -> Int? {
        guard let request = parseRequest(data),
              request.isContainerCreate,
              !request.bodyIsComplete else {
            return nil
        }
        if request.isChunked {
            return 4096
        }
        return max(0, request.contentLength - request.body.count)
    }

    static func headerBytesMissing(in data: Data) -> Bool {
        data.range(of: headerDelimiter) == nil
    }

    private static func parseRequest(_ data: Data) -> DockerCreateHTTPRequest? {
        guard let headerRange = data.range(of: headerDelimiter) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let body = data[bodyStart...]
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let transferEncoding = headers["transfer-encoding"]?.lowercased() ?? ""
        let path = requestParts[1]

        return DockerCreateHTTPRequest(
            method: requestParts[0],
            path: path,
            contentLength: contentLength,
            body: Data(body),
            containerName: containerName(from: path),
            transferEncoding: transferEncoding
        )
    }

    private static func containerName(from path: String) -> String? {
        guard let question = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: question)...]
        for item in query.split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.first == "name", parts.count == 2 else { continue }
            return parts[1].removingPercentEncoding
        }
        return nil
    }
}

struct DockerCreateResponseParser {
    private static let headerDelimiter = Data([13, 10, 13, 10])

    static func containerID(from data: Data) -> String? {
        guard let response = parseResponse(data),
              response.statusCode >= 200,
              response.statusCode < 300,
              response.bodyIsComplete,
              let decoded = try? JSONDecoder().decode(DockerCreateResponseBody.self, from: response.body),
              !decoded.id.isEmpty else {
            return nil
        }
        return decoded.id
    }

    static func additionalBodyBytesNeeded(in data: Data) -> Int? {
        guard let response = parseResponse(data),
              !response.bodyIsComplete else {
            return nil
        }
        return max(0, response.contentLength - response.body.count)
    }

    static func headerBytesMissing(in data: Data) -> Bool {
        data.range(of: headerDelimiter) == nil
    }

    private static func parseResponse(_ data: Data) -> DockerCreateHTTPResponse? {
        guard let headerRange = data.range(of: headerDelimiter) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        return DockerCreateHTTPResponse(
            statusCode: statusCode,
            contentLength: Int(headers["content-length"] ?? "") ?? 0,
            body: Data(data[bodyStart...])
        )
    }
}

struct DockerStartRequestParser {
    private static let headerDelimiter = Data([13, 10, 13, 10])

    static func startRequest(from data: Data) -> DockerContainerStartRequest? {
        guard let request = parseRequest(data),
              request.method == "POST",
              let containerID = containerID(from: request.path) else {
            return nil
        }
        return DockerContainerStartRequest(requestPath: request.path, containerID: containerID)
    }

    static func headerBytesMissing(in data: Data) -> Bool {
        data.range(of: headerDelimiter) == nil
    }

    private static func parseRequest(_ data: Data) -> DockerStartHTTPRequest? {
        guard let headerRange = data.range(of: headerDelimiter) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }
        return DockerStartHTTPRequest(method: requestParts[0], path: requestParts[1])
    }

    private static func containerID(from path: String) -> String? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let startIndex: Int
        if components.count >= 3, components[0] == "containers" {
            startIndex = 0
        } else if components.count >= 4, components[0].first == "v", components[1] == "containers" {
            startIndex = 1
        } else {
            return nil
        }
        guard components.count > startIndex + 2, components[startIndex + 2] == "start" else {
            return nil
        }
        let id = components[startIndex + 1].removingPercentEncoding ?? components[startIndex + 1]
        return id.isEmpty ? nil : id
    }
}

struct DockerContainerLifecycleRequestParser {
    private static let headerDelimiter = Data([13, 10, 13, 10])

    static func containerID(from data: Data) -> String? {
        guard let headerRange = data.range(of: headerDelimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8),
              let requestLine = headerText.split(separator: "\r\n", maxSplits: 1).first else {
            return nil
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let containerIndex: Int
        if components.count >= 2, components[0] == "containers" {
            containerIndex = 1
        } else if components.count >= 3, components[0].first == "v", components[1] == "containers" {
            containerIndex = 2
        } else {
            return nil
        }
        guard components.indices.contains(containerIndex) else { return nil }
        if method == "DELETE" {
            return decodedContainerID(components[containerIndex])
        }
        guard method == "POST",
              components.count > containerIndex + 1,
              ["stop", "kill", "wait"].contains(components[containerIndex + 1]) else {
            return nil
        }
        return decodedContainerID(components[containerIndex])
    }

    private static func decodedContainerID(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        return decoded.isEmpty ? nil : decoded
    }
}

struct DockerStartResponseParser {
    private static let headerDelimiter = Data([13, 10, 13, 10])

    static func succeeded(from data: Data) -> Bool {
        guard let statusCode = statusCode(from: data) else { return false }
        return statusCode >= 200 && statusCode < 300
    }

    static func headerBytesMissing(in data: Data) -> Bool {
        data.range(of: headerDelimiter) == nil
    }

    private static func statusCode(from data: Data) -> Int? {
        guard let headerRange = data.range(of: headerDelimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2 else { return nil }
        return Int(statusParts[1])
    }
}

private struct DockerCreateHTTPRequest {
    var method: String
    var path: String
    var contentLength: Int
    var body: Data
    var containerName: String?
    var transferEncoding: String

    var bodyIsComplete: Bool {
        if isChunked {
            return Self.decodeChunkedBody(body) != nil
        }
        return body.count >= contentLength
    }

    var decodedBody: Data? {
        if isChunked {
            return Self.decodeChunkedBody(body)
        }
        return body
    }

    var isChunked: Bool {
        transferEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("chunked")
    }

    var isContainerCreate: Bool {
        guard method == "POST" else { return false }
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.count >= 2, components[0] == "containers", components[1] == "create" {
            return true
        }
        if components.count >= 3,
           components[0].first == "v",
           components[1] == "containers",
           components[2] == "create" {
            return true
        }
        return false
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var index = data.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = data[index...].range(of: Data([13, 10]))?.lowerBound else {
                return nil
            }
            let lineData = data[index..<lineEnd]
            guard let line = String(data: lineData, encoding: .utf8) else {
                return nil
            }
            let sizeText = line
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeText, radix: 16) else {
                return nil
            }
            index = lineEnd + 2
            if size == 0 {
                guard data[index...].range(of: Data([13, 10])) != nil else {
                    return nil
                }
                return decoded
            }
            let chunkEnd = index + size
            guard chunkEnd + 2 <= data.endIndex else {
                return nil
            }
            decoded.append(data[index..<chunkEnd])
            guard data[chunkEnd] == 13, data[chunkEnd + 1] == 10 else {
                return nil
            }
            index = chunkEnd + 2
        }
    }
}

private struct DockerStartHTTPRequest {
    var method: String
    var path: String
}

private struct DockerCreateHTTPResponse {
    var statusCode: Int
    var contentLength: Int
    var body: Data

    var bodyIsComplete: Bool {
        body.count >= contentLength
    }
}

private struct DockerCreateResponseBody: Decodable {
    var id: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

private struct DockerCreatePortBindingsEnvelope: Decodable {
    var hostConfig: DockerCreateHostConfig?

    private enum CodingKeys: String, CodingKey {
        case hostConfig = "HostConfig"
    }
}

private struct DockerCreateHostConfig: Decodable {
    var portBindings: [String: [DockerCreatePortBinding]]

    private enum CodingKeys: String, CodingKey {
        case portBindings = "PortBindings"
    }
}

private struct DockerCreatePortBinding: Decodable {
    var hostIP: String?
    var hostPort: String?

    private enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}
