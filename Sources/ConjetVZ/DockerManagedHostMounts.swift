import ConjetCore
import Darwin
import Foundation

public struct DockerManagedHostMountRewriteResult: Sendable {
    public var requestData: Data
    public var mounts: [DockerManagedHostMountBinding]
}

public struct DockerManagedHostMountBinding: Codable, Equatable, Sendable {
    public var hostPath: String
    public var volumeName: String
    public var targetPath: String
    public var readOnly: Bool

    public init(hostPath: String, volumeName: String, targetPath: String, readOnly: Bool) {
        self.hostPath = hostPath
        self.volumeName = volumeName
        self.targetPath = targetPath
        self.readOnly = readOnly
    }
}

public protocol DockerManagedHostMounting: Sendable {
    func rewriteCreateRequest(_ data: Data) throws -> DockerManagedHostMountRewriteResult?
    func register(containerID: String, rewrite: DockerManagedHostMountRewriteResult)
    @discardableResult func copyBack(containerID: String) throws -> Int
    @discardableResult func copyBackBeforeContainerRemoval(requestData: Data) throws -> Int
    @discardableResult func copyBackAfterContainerWait(requestData: Data) throws -> Int
}

final class DockerManagedHostMountCoordinator: DockerManagedHostMounting, @unchecked Sendable {
    private let connector: any GuestConnectionConnector
    private let allowedHostPathPrefixes: [String]
    private let requestGuestControlMounts: Bool
    private let requireGuestControlMounts: Bool
    private let workDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var mountsByContainerID: [String: [DockerManagedHostMountBinding]] = [:]
    private var requestedVirtioFSMountTargets: Set<String> = []

    init(
        connector: any GuestConnectionConnector,
        allowedHostPathPrefixes: [String],
        requestGuestControlMounts: Bool = true,
        requireGuestControlMounts: Bool = false,
        workDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjet-managed-host-mounts", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.connector = connector
        self.allowedHostPathPrefixes = allowedHostPathPrefixes
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardized.path }
        self.requestGuestControlMounts = requestGuestControlMounts
        self.requireGuestControlMounts = requireGuestControlMounts
        self.workDirectory = workDirectory
        self.fileManager = fileManager
    }

    func rewriteCreateRequest(_ data: Data) throws -> DockerManagedHostMountRewriteResult? {
        guard let rewrite = try DockerManagedHostMountRequestRewriter.rewrite(
            data,
            allowedHostPathPrefixes: allowedHostPathPrefixes
        ) else {
            return nil
        }
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let client = DockerGuestHTTPClient(connector: connector)
        for mount in rewrite.mounts {
            try prepare(mount: mount, client: client)
        }
        return rewrite
    }

    func register(containerID: String, rewrite: DockerManagedHostMountRewriteResult) {
        guard !rewrite.mounts.isEmpty else { return }
        lock.lock()
        mountsByContainerID[containerID] = rewrite.mounts
        lock.unlock()
    }

    func copyBackBeforeContainerRemoval(requestData: Data) throws -> Int {
        guard let containerID = DockerContainerRemoveRequestParser.containerID(from: requestData) else {
            return 0
        }
        lock.lock()
        let mounts = mountsByContainerID.removeValue(forKey: containerID)
        lock.unlock()
        return try copyBack(mounts: mounts)
    }

    func copyBackAfterContainerWait(requestData: Data) throws -> Int {
        guard let containerID = DockerContainerWaitRequestParser.containerID(from: requestData) else {
            return 0
        }
        lock.lock()
        let mounts = mountsByContainerID[containerID]
        lock.unlock()
        return try copyBack(mounts: mounts)
    }

    func copyBack(containerID: String) throws -> Int {
        lock.lock()
        let mounts = mountsByContainerID[containerID]
        lock.unlock()
        return try copyBack(mounts: mounts)
    }

    private func copyBack(mounts: [DockerManagedHostMountBinding]?) throws -> Int {
        guard let mounts, !mounts.isEmpty else { return 0 }
        let client = DockerGuestHTTPClient(connector: connector)
        var copied = 0
        for mount in mounts where !mount.readOnly {
            try copyBack(mount: mount, client: client)
            copied += 1
        }
        return copied
    }

    private func prepare(mount: DockerManagedHostMountBinding, client: DockerGuestHTTPClient) throws {
        try requestGuestVirtioFSMountIfNeeded(forHostPath: mount.hostPath)
        let hostURL = URL(fileURLWithPath: mount.hostPath, isDirectory: true)
        let archive = try DockerManagedHostMountTar.archiveDirectory(hostURL, workDirectory: workDirectory)
        defer { try? fileManager.removeItem(at: archive.url) }
        try? client.removeVolume(named: mount.volumeName)
        try client.ensureVolume(named: mount.volumeName)
        let helperID = try client.createHelperContainer(volumeName: mount.volumeName, cleanOnStart: true)
        defer { try? client.removeContainer(id: helperID) }
        try client.startContainer(id: helperID)
        try client.putArchive(containerID: helperID, path: "/sync", archive: archive)
    }

    private func requestGuestVirtioFSMountIfNeeded(forHostPath hostPath: String) throws {
        guard requestGuestControlMounts else {
            return
        }
        guard let request = GuestControlClient.mountRequest(forHostPath: hostPath) else {
            return
        }
        lock.lock()
        if requestedVirtioFSMountTargets.contains(request.target) {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            _ = try GuestControlClient(connector: connector).mountVirtioFS(tag: request.tag, target: request.target)
            lock.lock()
            requestedVirtioFSMountTargets.insert(request.target)
            lock.unlock()
        } catch {
            if requireGuestControlMounts {
                throw error
            }
        }
    }

    private func copyBack(mount: DockerManagedHostMountBinding, client: DockerGuestHTTPClient) throws {
        let helperID = try client.createHelperContainer(volumeName: mount.volumeName, cleanOnStart: false)
        defer { try? client.removeContainer(id: helperID) }
        try client.startContainer(id: helperID)
        let archive = try client.getArchive(containerID: helperID, path: "/sync")
        try DockerManagedHostMountTar.extractDockerDirectoryArchive(
            archive,
            to: URL(fileURLWithPath: mount.hostPath, isDirectory: true),
            workDirectory: workDirectory
        )
    }
}

enum DockerManagedHostMountRequestRewriter {
    static func rewrite(
        _ data: Data,
        allowedHostPathPrefixes: [String]
    ) throws -> DockerManagedHostMountRewriteResult? {
        guard let request = try DockerHTTPMessage.parseRequest(data),
              request.method == "POST",
              request.isContainerCreate,
              let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return nil
        }

        var root = json
        var hostConfig = root["HostConfig"] as? [String: Any] ?? [:]
        var bindings: [DockerManagedHostMountBinding] = []

        if var mounts = hostConfig["Mounts"] as? [[String: Any]] {
            var changed = false
            for index in mounts.indices {
                guard let type = stringValue(mounts[index]["Type"])?.lowercased(),
                      type == "bind",
                      let source = stringValue(mounts[index]["Source"] ?? mounts[index]["SourcePath"]),
                      let target = stringValue(mounts[index]["Target"] ?? mounts[index]["Destination"]),
                      let binding = makeBinding(
                          source: source,
                          target: target,
                          readOnly: boolValue(mounts[index]["ReadOnly"]) ?? false,
                          allowedHostPathPrefixes: allowedHostPathPrefixes
                      ) else {
                    continue
                }
                mounts[index]["Type"] = "volume"
                mounts[index]["Source"] = binding.volumeName
                mounts[index].removeValue(forKey: "SourcePath")
                mounts[index].removeValue(forKey: "BindOptions")
                mounts[index].removeValue(forKey: "Consistency")
                bindings.append(binding)
                changed = true
            }
            if changed {
                hostConfig["Mounts"] = mounts
            }
        }

        if let binds = hostConfig["Binds"] as? [String] {
            var changed = false
            var rewritten: [String] = []
            for bind in binds {
                guard let parsed = parseBind(bind),
                      let binding = makeBinding(
                          source: parsed.source,
                          target: parsed.target,
                          readOnly: parsed.options.split(separator: ",").contains("ro"),
                          allowedHostPathPrefixes: allowedHostPathPrefixes
                      ) else {
                    rewritten.append(bind)
                    continue
                }
                let options = parsed.options.isEmpty ? "rw" : parsed.options
                rewritten.append("\(binding.volumeName):\(binding.targetPath):\(options)")
                bindings.append(binding)
                changed = true
            }
            if changed {
                hostConfig["Binds"] = rewritten
            }
        }

        guard !bindings.isEmpty else { return nil }
        root["HostConfig"] = hostConfig
        let body = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return DockerManagedHostMountRewriteResult(
            requestData: request.replacingBody(body),
            mounts: Array(Dictionary(grouping: bindings, by: \.hostPath).values.compactMap(\.first))
        )
    }

    private static func makeBinding(
        source: String,
        target: String,
        readOnly: Bool,
        allowedHostPathPrefixes: [String]
    ) -> DockerManagedHostMountBinding? {
        let sourceURL = URL(fileURLWithPath: source, isDirectory: true).standardized
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              target.hasPrefix("/"),
              isAllowed(sourceURL.path, allowedHostPathPrefixes: allowedHostPathPrefixes) else {
            return nil
        }
        return DockerManagedHostMountBinding(
            hostPath: sourceURL.path,
            volumeName: "conjet-hostsync-\(fnv1a64Hex(sourceURL.path))",
            targetPath: target,
            readOnly: readOnly
        )
    }

    private static func parseBind(_ bind: String) -> (source: String, target: String, options: String)? {
        let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let options = parts.count >= 3 ? parts[2...].joined(separator: ":") : "rw"
        return (parts[0], parts[1], options)
    }

    private static func isAllowed(_ path: String, allowedHostPathPrefixes: [String]) -> Bool {
        allowedHostPathPrefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

enum DockerContainerRemoveRequestParser {
    static func containerID(from data: Data) -> String? {
        guard let request = try? DockerHTTPMessage.parseRequest(data),
              request.method == "DELETE" else {
            return nil
        }
        let pathOnly = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let containerIndex: Int
        if components.count >= 2, components[0] == "containers" {
            containerIndex = 1
        } else if components.count >= 3, components[0].first == "v", components[1] == "containers" {
            containerIndex = 2
        } else {
            return nil
        }
        let id = components[containerIndex].removingPercentEncoding ?? components[containerIndex]
        return id.isEmpty ? nil : id
    }
}

enum DockerContainerWaitRequestParser {
    static func containerID(from data: Data) -> String? {
        guard let request = try? DockerHTTPMessage.parseRequest(data),
              request.method == "POST" else {
            return nil
        }
        let pathOnly = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let containerIndex: Int
        let waitIndex: Int
        if components.count >= 3, components[0] == "containers" {
            containerIndex = 1
            waitIndex = 2
        } else if components.count >= 4, components[0].first == "v", components[1] == "containers" {
            containerIndex = 2
            waitIndex = 3
        } else {
            return nil
        }
        guard components[waitIndex] == "wait" else { return nil }
        let id = components[containerIndex].removingPercentEncoding ?? components[containerIndex]
        return id.isEmpty ? nil : id
    }
}

enum DockerContainerAttachRequestParser {
    static func containerID(from data: Data) -> String? {
        guard let request = try? DockerHTTPMessage.parseRequest(data) else {
            return nil
        }
        let pathOnly = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let containerIndex: Int
        let attachIndex: Int
        if components.count >= 3, components[0] == "containers" {
            containerIndex = 1
            attachIndex = 2
        } else if components.count >= 4, components[0].first == "v", components[1] == "containers" {
            containerIndex = 2
            attachIndex = 3
        } else {
            return nil
        }
        guard components[attachIndex] == "attach" else { return nil }
        let id = components[containerIndex].removingPercentEncoding ?? components[containerIndex]
        return id.isEmpty ? nil : id
    }
}

private struct DockerGuestHTTPClient {
    private static let helperImage = "busybox:1.36"

    var connector: any GuestConnectionConnector

    func ensureVolume(named name: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name], options: [])
        let response = try request(method: "POST", path: "/v1.45/volumes/create", body: body)
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest Docker volume create failed for \(name): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
    }

    func removeVolume(named name: String) throws {
        let response = try request(
            method: "DELETE",
            path: "/v1.45/volumes/\(urlEncode(name))?force=true",
            body: nil
        )
        guard response.statusCode == 404 || (response.statusCode >= 200 && response.statusCode < 300) else {
            throw ConjetError.unavailable(
                "guest Docker volume remove failed for \(name): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
    }

    func createHelperContainer(volumeName: String, cleanOnStart: Bool) throws -> String {
        let body = try helperCreateBody(volumeName: volumeName, cleanOnStart: cleanOnStart)
        let response = try createHelperContainer(body: body)
        if response.statusCode == 404 && response.bodySummary.localizedCaseInsensitiveContains("No such image") {
            try pullImage(Self.helperImage)
            return try parseHelperCreateResponse(try createHelperContainer(body: body))
        }
        return try parseHelperCreateResponse(response)
    }

    private func helperCreateBody(volumeName: String, cleanOnStart: Bool) throws -> Data {
        let command = cleanOnStart
            ? "rm -rf /sync/* /sync/.[!.]* /sync/..?* 2>/dev/null || true; sleep 300"
            : "sleep 300"
        let bodyObject: [String: Any] = [
            "Image": Self.helperImage,
            "Cmd": ["sh", "-c", command],
            "HostConfig": [
                "Binds": ["\(volumeName):/sync:rw"]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: bodyObject, options: [])
    }

    private func createHelperContainer(body: Data) throws -> DockerHTTPResponse {
        try request(
            method: "POST",
            path: "/v1.45/containers/create?name=conjet-hostsync-\(UUID().uuidString)",
            body: body
        )
    }

    private func parseHelperCreateResponse(_ response: DockerHTTPResponse) throws -> String {
        guard response.statusCode >= 200 && response.statusCode < 300,
              let id = containerID(from: response.body),
              !id.isEmpty else {
            throw ConjetError.unavailable(
                "guest Docker helper create failed: HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
        return id
    }

    private func pullImage(_ image: String) throws {
        let parts = splitImageReference(image)
        let response = try request(
            method: "POST",
            path: "/v1.45/images/create?fromImage=\(urlEncode(parts.repository))&tag=\(urlEncode(parts.tag))",
            body: Data()
        )
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest Docker helper image pull failed for \(image): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
    }

    func startContainer(id: String) throws {
        let response = try request(method: "POST", path: "/v1.45/containers/\(id)/start", body: Data())
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest Docker helper start failed for \(id): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
    }

    func putArchive(containerID: String, path: String, archive: Data) throws {
        let response = try request(
            method: "PUT",
            path: "/v1.45/containers/\(containerID)/archive?path=\(urlEncode(path))",
            body: archive,
            contentType: "application/x-tar"
        )
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest Docker archive upload failed for \(containerID): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
    }

    func putArchive(containerID: String, path: String, archive: DockerManagedHostMountArchive) throws {
        let response = try requestFile(
            method: "PUT",
            path: "/v1.45/containers/\(containerID)/archive?path=\(urlEncode(path))",
            fileURL: archive.url,
            fileSize: archive.size,
            contentType: "application/x-tar"
        )
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest Docker archive upload failed for \(containerID): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
    }

    func getArchive(containerID: String, path: String) throws -> Data {
        let response = try request(
            method: "GET",
            path: "/v1.45/containers/\(containerID)/archive?path=\(urlEncode(path))",
            body: nil
        )
        guard response.statusCode >= 200 && response.statusCode < 300 else {
            throw ConjetError.unavailable(
                "guest Docker archive download failed for \(containerID): HTTP \(response.statusCode) \(response.bodySummary)"
            )
        }
        return response.body
    }

    func removeContainer(id: String) throws {
        _ = try request(method: "DELETE", path: "/v1.45/containers/\(id)?force=true&v=false", body: nil)
    }

    private func request(
        method: String,
        path: String,
        body: Data?,
        contentType: String = "application/json"
    ) throws -> DockerHTTPResponse {
        try request(
            method: method,
            path: path,
            contentLength: UInt64(body?.count ?? 0),
            contentType: body == nil ? nil : contentType
        ) { fd in
            guard let body, !body.isEmpty else { return }
            guard dockerManagedWriteAll(body, to: fd) else {
                throw ConjetError.socket("failed to write guest Docker API request body")
            }
        }
    }

    private func requestFile(
        method: String,
        path: String,
        fileURL: URL,
        fileSize: UInt64,
        contentType: String
    ) throws -> DockerHTTPResponse {
        try request(
            method: method,
            path: path,
            contentLength: fileSize,
            contentType: contentType
        ) { fd in
            try dockerManagedWriteFile(fileURL, to: fd)
        }
    }

    private func request(
        method: String,
        path: String,
        contentLength: UInt64,
        contentType: String?,
        writeBody: (Int32) throws -> Void
    ) throws -> DockerHTTPResponse {
        let connection = try connector.connect()
        defer { connection.close() }

        var headers = [
            "\(method) \(path) HTTP/1.1",
            "Host: docker",
            "Connection: close"
        ]
        if let contentType {
            headers.append("Content-Type: \(contentType)")
        }
        headers.append("Content-Length: \(contentLength)")
        let head = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        guard dockerManagedWriteAll(head, to: connection.fileDescriptor) else {
            throw ConjetError.socket("failed to write guest Docker API request")
        }
        try writeBody(connection.fileDescriptor)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = dockerManagedReadIntoBuffer(connection.fileDescriptor, buffer: &buffer)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        return try DockerHTTPResponse.parse(data)
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func splitImageReference(_ image: String) -> (repository: String, tag: String) {
        let slashIndex = image.lastIndex(of: "/")
        if let colonIndex = image.lastIndex(of: ":"),
           slashIndex == nil || colonIndex > slashIndex! {
            return (
                String(image[..<colonIndex]),
                String(image[image.index(after: colonIndex)...])
            )
        }
        return (image, "latest")
    }

    private func containerID(from body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let id = object["Id"] as? String,
           !id.isEmpty {
            return id
        }
        guard let text = String(data: body, encoding: .utf8),
              let range = text.range(of: #""Id"\s*:\s*""#, options: .regularExpression) else {
            return nil
        }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let id = String(rest[..<end])
        return id.isEmpty ? nil : id
    }
}

private struct DockerManagedHostMountArchive {
    var url: URL
    var size: UInt64
}

private struct DockerManagedHostMountTar {
    static func archiveDirectory(_ root: URL, workDirectory: URL) throws -> DockerManagedHostMountArchive {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let archiveURL = workDirectory.appendingPathComponent("\(UUID().uuidString).tar")
        let result = try ProcessRunner.run(
            "/usr/bin/tar",
            ["--no-xattrs", "--no-mac-metadata", "-C", root.path, "-cf", archiveURL.path, "."]
        )
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        let values = try archiveURL.resourceValues(forKeys: [.fileSizeKey])
        return DockerManagedHostMountArchive(url: archiveURL, size: UInt64(values.fileSize ?? 0))
    }

    static func extractDockerDirectoryArchive(_ archive: Data, to hostRoot: URL, workDirectory: URL) throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let archiveURL = workDirectory.appendingPathComponent("\(UUID().uuidString).tar")
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        try archive.write(to: archiveURL, options: .atomic)
        try validateDockerDirectoryArchive(archiveURL)
        let result = try ProcessRunner.run(
            "/usr/bin/tar",
            ["--strip-components", "1", "-C", hostRoot.path, "-xf", archiveURL.path]
        )
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    private static func validateDockerDirectoryArchive(_ archiveURL: URL) throws {
        let listing = try ProcessRunner.run("/usr/bin/tar", ["-tf", archiveURL.path])
        guard listing.succeeded else {
            throw ConjetError.processFailed(
                executable: listing.executable,
                exitCode: listing.exitCode,
                stderr: listing.stderr.isEmpty ? listing.stdout : listing.stderr
            )
        }
        let entries = listing.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            throw ConjetError.decoding("guest Docker archive was empty")
        }
        for entry in entries {
            let normalized = entry.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !entry.hasPrefix("/"),
                  normalized == "sync" || normalized.hasPrefix("sync/"),
                  !normalized.split(separator: "/").contains("..") else {
                throw ConjetError.decoding("guest Docker archive contained unexpected path \(entry)")
            }
        }
    }
}

private struct DockerHTTPMessage {
    var method: String
    var path: String
    var version: String
    var headers: [(String, String)]
    var body: Data

    var isContainerCreate: Bool {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let components = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.count >= 2, components[0] == "containers", components[1] == "create" {
            return true
        }
        return components.count >= 3
            && components[0].first == "v"
            && components[1] == "containers"
            && components[2] == "create"
    }

    static func parseRequest(_ data: Data) throws -> DockerHTTPMessage? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }

        var headers: [(String, String)] = []
        var transferEncoding = ""
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.lowercased() == "transfer-encoding" {
                transferEncoding = value.lowercased()
            }
            if key.lowercased() == "content-length" {
                contentLength = Int(value)
            }
            headers.append((key, value))
        }

        let rawBody = Data(data[headerRange.upperBound...])
        let body = transferEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("chunked")
            ? decodeChunkedBody(rawBody) ?? rawBody
            : Data(rawBody.prefix(contentLength ?? rawBody.count))
        return DockerHTTPMessage(method: parts[0], path: parts[1], version: parts[2], headers: headers, body: body)
    }

    func replacingBody(_ newBody: Data) -> Data {
        var lines = ["\(method) \(path) \(version)"]
        var sawHost = false
        for (key, value) in headers {
            switch key.lowercased() {
            case "content-length", "transfer-encoding":
                continue
            case "host":
                sawHost = true
                lines.append("\(key): \(value)")
            default:
                lines.append("\(key): \(value)")
            }
        }
        if !sawHost {
            lines.append("Host: docker")
        }
        lines.append("Content-Length: \(newBody.count)")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(newBody)
        return data
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var index = data.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = data[index...].range(of: Data([13, 10]))?.lowerBound,
                  let line = String(data: data[index..<lineEnd], encoding: .utf8),
                  let sizeText = line
                      .split(separator: ";", maxSplits: 1)
                      .first
                      .map(String.init)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  let size = Int(sizeText, radix: 16) else {
                return nil
            }
            index = lineEnd + 2
            if size == 0 {
                return decoded
            }
            let chunkEnd = index + size
            guard chunkEnd + 2 <= data.endIndex else { return nil }
            decoded.append(data[index..<chunkEnd])
            index = chunkEnd + 2
        }
    }
}

private struct DockerHTTPResponse {
    var statusCode: Int
    var body: Data

    var bodySummary: String {
        guard !body.isEmpty else { return "" }
        let text = String(data: body.prefix(512), encoding: .utf8) ?? "\(body.prefix(128) as NSData)"
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ data: Data) throws -> DockerHTTPResponse {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw ConjetError.decoding("invalid Docker HTTP response")
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        let statusLine = lines.first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw ConjetError.decoding("invalid Docker HTTP status line")
        }
        var contentLength: Int?
        var transferEncoding = ""
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "content-length" {
                contentLength = Int(value)
            }
            if key == "transfer-encoding" {
                transferEncoding = value.lowercased()
            }
        }
        let rawBody = Data(data[headerRange.upperBound...])
        let body = transferEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("chunked")
            ? decodeChunkedBody(rawBody) ?? rawBody
            : Data(rawBody.prefix(contentLength ?? rawBody.count))
        return DockerHTTPResponse(statusCode: statusCode, body: body)
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var index = data.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = data[index...].range(of: Data([13, 10]))?.lowerBound,
                  let line = String(data: data[index..<lineEnd], encoding: .utf8),
                  let sizeText = line
                      .split(separator: ";", maxSplits: 1)
                      .first
                      .map(String.init)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  let size = Int(sizeText, radix: 16) else {
                return nil
            }
            index = lineEnd + 2
            if size == 0 {
                return decoded
            }
            let chunkEnd = index + size
            guard chunkEnd + 2 <= data.endIndex else { return nil }
            decoded.append(data[index..<chunkEnd])
            index = chunkEnd + 2
        }
    }
}

private func dockerManagedWriteAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return true
        }
        var written = 0
        while written < data.count {
            let count = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

private func dockerManagedWriteFile(_ url: URL, to fd: Int32) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while true {
        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        if chunk.isEmpty {
            return
        }
        guard dockerManagedWriteAll(chunk, to: fd) else {
            throw ConjetError.socket("failed to write guest Docker API request body")
        }
    }
}

private func dockerManagedReadIntoBuffer(_ fd: Int32, buffer: inout [UInt8]) -> Int {
    let count = buffer.count
    return buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        guard let baseAddress = rawBuffer.baseAddress else {
            return -1
        }
        return Darwin.read(fd, baseAddress, count)
    }
}
