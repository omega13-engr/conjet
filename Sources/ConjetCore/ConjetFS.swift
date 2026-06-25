import Foundation

public struct ConjetProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var hostRoot: String
    public var dockerVolume: String
    public var guestPath: String
    public var createdAt: String

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        hostRoot: String,
        dockerVolume: String,
        guestPath: String = "/workspace",
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.hostRoot = hostRoot
        self.dockerVolume = dockerVolume
        self.guestPath = guestPath
        self.createdAt = createdAt
    }
}

public struct ConjetFSFileSignature: Codable, Equatable, Sendable {
    public var bytes: Int64
    public var modifiedAtNanoseconds: Int64

    public init(bytes: Int64, modifiedAtNanoseconds: Int64) {
        self.bytes = bytes
        self.modifiedAtNanoseconds = modifiedAtNanoseconds
    }
}

public struct ConjetFSFileEntry: Codable, Equatable, Sendable {
    public var path: String
    public var bytes: Int64
    public var classification: PathClassification
    public var signature: ConjetFSFileSignature

    public init(
        path: String,
        bytes: Int64,
        classification: PathClassification,
        signature: ConjetFSFileSignature? = nil
    ) {
        self.path = path
        self.bytes = bytes
        self.classification = classification
        self.signature = signature ?? ConjetFSFileSignature(bytes: bytes, modifiedAtNanoseconds: 0)
    }
}

public struct ConjetFSSyncPlan: Codable, Equatable, Sendable {
    public var project: ConjetProject
    public var includedFiles: [ConjetFSFileEntry]
    public var changedFiles: [ConjetFSFileEntry]
    public var skippedFiles: [ConjetFSFileEntry]
    public var removedFiles: [String]
    public var projectKinds: [ProjectKind]

    public init(
        project: ConjetProject,
        includedFiles: [ConjetFSFileEntry],
        changedFiles: [ConjetFSFileEntry]? = nil,
        skippedFiles: [ConjetFSFileEntry],
        removedFiles: [String],
        projectKinds: [ProjectKind]
    ) {
        self.project = project
        self.includedFiles = includedFiles
        self.changedFiles = changedFiles ?? includedFiles
        self.skippedFiles = skippedFiles
        self.removedFiles = removedFiles
        self.projectKinds = projectKinds
    }

    public var includedBytes: Int64 {
        includedFiles.reduce(0) { $0 + $1.bytes }
    }

    public var skippedBytes: Int64 {
        skippedFiles.reduce(0) { $0 + $1.bytes }
    }

    public var changedBytes: Int64 {
        changedFiles.reduce(0) { $0 + $1.bytes }
    }
}

public struct ConjetFSSyncResult: Codable, Equatable, Sendable {
    public var project: ConjetProject
    public var dockerContext: String
    public var guestPath: String
    public var includedFiles: Int
    public var changedFiles: Int
    public var skippedFiles: Int
    public var removedFiles: Int
    public var includedBytes: Int64
    public var changedBytes: Int64
    public var skippedBytes: Int64
    public var dockerVolume: String
    public var containerMountArgument: String

    public init(
        project: ConjetProject,
        dockerContext: String,
        guestPath: String,
        includedFiles: Int,
        changedFiles: Int? = nil,
        skippedFiles: Int,
        removedFiles: Int,
        includedBytes: Int64,
        changedBytes: Int64? = nil,
        skippedBytes: Int64,
        dockerVolume: String,
        containerMountArgument: String
    ) {
        self.project = project
        self.dockerContext = dockerContext
        self.guestPath = guestPath
        self.includedFiles = includedFiles
        self.changedFiles = changedFiles ?? includedFiles
        self.skippedFiles = skippedFiles
        self.removedFiles = removedFiles
        self.includedBytes = includedBytes
        self.changedBytes = changedBytes ?? includedBytes
        self.skippedBytes = skippedBytes
        self.dockerVolume = dockerVolume
        self.containerMountArgument = containerMountArgument
    }
}

public struct ConjetFSManifest: Codable, Equatable, Sendable {
    public var projectID: String
    public var syncedFiles: [String]
    public var fileSignatures: [String: ConjetFSFileSignature]
    public var updatedAt: String

    public init(
        projectID: String,
        syncedFiles: [String],
        fileSignatures: [String: ConjetFSFileSignature] = [:],
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.projectID = projectID
        self.syncedFiles = syncedFiles
        self.fileSignatures = fileSignatures
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case syncedFiles
        case fileSignatures
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectID = try container.decode(String.self, forKey: .projectID)
        self.syncedFiles = try container.decode([String].self, forKey: .syncedFiles)
        self.fileSignatures = try container.decodeIfPresent(
            [String: ConjetFSFileSignature].self,
            forKey: .fileSignatures
        ) ?? [:]
        self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? ISO8601DateFormatter().string(from: Date())
    }
}

public struct ConjetFSStatus: Codable, Equatable, Sendable {
    public var project: ConjetProject
    public var dockerContext: String
    public var guestPath: String
    public var dockerVolume: String
    public var hostSyncedFiles: Int
    public var changedFiles: Int
    public var removedFiles: Int
    public var skippedFiles: Int
    public var hostSyncedBytes: Int64
    public var changedBytes: Int64
    public var skippedBytes: Int64
    public var manifestUpdatedAt: String?
    public var dirty: Bool

    public init(
        project: ConjetProject,
        dockerContext: String,
        guestPath: String,
        dockerVolume: String,
        hostSyncedFiles: Int,
        changedFiles: Int,
        removedFiles: Int,
        skippedFiles: Int,
        hostSyncedBytes: Int64,
        changedBytes: Int64,
        skippedBytes: Int64,
        manifestUpdatedAt: String?,
        dirty: Bool
    ) {
        self.project = project
        self.dockerContext = dockerContext
        self.guestPath = guestPath
        self.dockerVolume = dockerVolume
        self.hostSyncedFiles = hostSyncedFiles
        self.changedFiles = changedFiles
        self.removedFiles = removedFiles
        self.skippedFiles = skippedFiles
        self.hostSyncedBytes = hostSyncedBytes
        self.changedBytes = changedBytes
        self.skippedBytes = skippedBytes
        self.manifestUpdatedAt = manifestUpdatedAt
        self.dirty = dirty
    }
}

public struct ConjetFSExportResult: Codable, Equatable, Sendable {
    public var project: ConjetProject
    public var dockerContext: String
    public var dockerVolume: String
    public var guestPath: String
    public var exportedPaths: [String]
    public var hostDestination: String

    public init(
        project: ConjetProject,
        dockerContext: String,
        dockerVolume: String,
        guestPath: String,
        exportedPaths: [String],
        hostDestination: String
    ) {
        self.project = project
        self.dockerContext = dockerContext
        self.dockerVolume = dockerVolume
        self.guestPath = guestPath
        self.exportedPaths = exportedPaths
        self.hostDestination = hostDestination
    }
}

public struct ConjetFSRunPreparation: Codable, Equatable, Sendable {
    public var sync: ConjetFSSyncResult
    public var dockerMountArguments: [String]
    public var shellPrelude: String

    public init(sync: ConjetFSSyncResult, dockerMountArguments: [String], shellPrelude: String) {
        self.sync = sync
        self.dockerMountArguments = dockerMountArguments
        self.shellPrelude = shellPrelude
    }
}

public typealias ConjetFSDockerRunner = (String, [String]) throws -> ProcessResult
public typealias ConjetFSDockerInputRunner = (String, [String], Data?) throws -> ProcessResult

public struct ConjetFS {
    public var projectRoot: URL
    public var paths: ConjetPaths
    public var dockerContext: String
    public var dockerExecutable: String

    private let runner: ConjetFSDockerRunner
    private let inputRunner: ConjetFSDockerInputRunner
    private let streamingHelperFastPath: Bool

    public init(
        projectRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        paths: ConjetPaths = .default(),
        dockerContext: String? = nil,
        dockerExecutable: String = "/usr/bin/env",
        runner: @escaping ConjetFSDockerRunner = ProcessRunner.run,
        inputRunner: @escaping ConjetFSDockerInputRunner = ProcessRunner.runWithInput,
        streamingHelperFastPath: Bool = false
    ) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.paths = paths
        self.dockerContext = dockerContext ?? Self.defaultDockerContext(profileName: paths.profileName)
        self.dockerExecutable = dockerExecutable
        self.runner = runner
        self.inputRunner = inputRunner
        self.streamingHelperFastPath = streamingHelperFastPath
    }

    public func initializeProject() throws -> ConjetProject {
        let root = try canonicalProjectRoot()
        let directory = Self.projectMetadataDirectory(root: root)
        let projectFile = Self.projectFile(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: projectFile.path) {
            return try loadProject()
        }

        let id = Self.projectID(for: root.path)
        let project = ConjetProject(
            id: id,
            name: root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent,
            hostRoot: root.path,
            dockerVolume: Self.volumeName(profileName: paths.profileName, projectName: root.lastPathComponent, projectID: id)
        )
        let data = try JSONEncoder.conjetPretty.encode(project)
        try data.write(to: projectFile, options: .atomic)

        let ignoreFile = root.appendingPathComponent(".conjetignore")
        if !FileManager.default.fileExists(atPath: ignoreFile.path) {
            try Self.defaultConjetIgnore.write(to: ignoreFile, atomically: true, encoding: .utf8)
        }

        return project
    }

    public func loadProject() throws -> ConjetProject {
        let projectFile = Self.projectFile(root: try canonicalProjectRoot())
        let data = try Data(contentsOf: projectFile)
        return try JSONDecoder().decode(ConjetProject.self, from: data)
    }

    public func loadOrInitializeProject() throws -> ConjetProject {
        let projectFile = Self.projectFile(root: try canonicalProjectRoot())
        if FileManager.default.fileExists(atPath: projectFile.path) {
            return try loadProject()
        }
        return try initializeProject()
    }

    public func makePlan(project: ConjetProject) throws -> ConjetFSSyncPlan {
        let root = try canonicalProjectRoot()
        let ignore = try Self.loadIgnore(root: root)
        let classifier = PathClassifier(ignore: ignore)
        let allPaths = try collectProjectPaths(root: root)
        let fingerprint = ProjectDetector.detect(files: allPaths)
        let previousManifest = try loadManifest(projectID: project.id)
        let previouslySynced = Set(previousManifest?.syncedFiles ?? [])
        let previousSignatures = previousManifest?.fileSignatures ?? [:]

        var included: [ConjetFSFileEntry] = []
        var changed: [ConjetFSFileEntry] = []
        var skipped: [ConjetFSFileEntry] = []
        let manager = FileManager.default

        for relativePath in allPaths {
            let fileURL = root.appendingPathComponent(relativePath)
            let attributes = try manager.attributesOfItem(atPath: fileURL.path)
            let type = attributes[.type] as? FileAttributeType
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let classification = classifier.classify(relativePath, projectKinds: fingerprint.kinds)
            let signature = Self.signature(bytes: bytes, attributes: attributes)
            let entry = ConjetFSFileEntry(
                path: relativePath,
                bytes: bytes,
                classification: classification,
                signature: signature
            )

            if type == .typeDirectory {
                switch classification.placement {
                case .vmNative, .ignored, .exportOnDemand:
                    skipped.append(entry)
                case .hostSynced, .lazySynced:
                    break
                }
                continue
            }

            guard type == .typeRegular || type == .typeSymbolicLink else {
                continue
            }

            switch classification.placement {
            case .hostSynced, .lazySynced:
                included.append(entry)
                if previousSignatures[relativePath] != signature {
                    changed.append(entry)
                }
            case .vmNative, .ignored, .exportOnDemand:
                skipped.append(entry)
            }
        }

        let currentSynced = Set(included.map(\.path))
        let removed = previouslySynced.subtracting(currentSynced).sorted()
        return ConjetFSSyncPlan(
            project: project,
            includedFiles: included.sorted { $0.path < $1.path },
            changedFiles: changed.sorted { $0.path < $1.path },
            skippedFiles: skipped.sorted { $0.path < $1.path },
            removedFiles: removed,
            projectKinds: fingerprint.kinds
        )
    }

    public func sync(project: ConjetProject) throws -> ConjetFSSyncResult {
        let plan = try makePlan(project: project)
        return try sync(plan: plan)
    }

    public func sync(
        project: ConjetProject,
        changedPaths rawChangedPaths: [String],
        helperContainer: String? = nil
    ) throws -> ConjetFSSyncResult {
        let changedPaths = try normalizeChangedPaths(rawChangedPaths)
        if changedPaths.isEmpty || changedPaths.contains(".") {
            return try sync(project: project)
        }

        let root = try canonicalProjectRoot()
        let ignore = try Self.loadIgnore(root: root)
        let classifier = PathClassifier(ignore: ignore)
        let projectKinds = try detectProjectKinds(root: root)
        let previousManifest = try loadManifest(projectID: project.id)
            ?? ConjetFSManifest(projectID: project.id, syncedFiles: [], fileSignatures: [:])
        var syncedFiles = Set(previousManifest.syncedFiles)
        var signatures = previousManifest.fileSignatures
        var changedEntries: [ConjetFSFileEntry] = []
        var skippedEntries: [ConjetFSFileEntry] = []
        var removedFiles: Set<String> = []

        for changedPath in changedPaths {
            let fileURL = root.appendingPathComponent(changedPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    let classification = classifier.classify(changedPath, projectKinds: projectKinds)
                    if classification.placement == .ignored || classification.placement == .vmNative {
                        skippedEntries.append(ConjetFSFileEntry(
                            path: changedPath,
                            bytes: 0,
                            classification: classification
                        ))
                    } else {
                        let childEntries = try collectChangedEntries(
                            root: root,
                            relativeRoot: changedPath,
                            classifier: classifier,
                            projectKinds: projectKinds,
                            signatures: signatures,
                            syncedFiles: &syncedFiles,
                            updatedSignatures: &signatures,
                            removedFiles: &removedFiles,
                            skippedEntries: &skippedEntries
                        )
                        changedEntries.append(contentsOf: childEntries)
                    }
                } else if let entry = try changedEntry(
                    root: root,
                    relativePath: changedPath,
                    classifier: classifier,
                    projectKinds: projectKinds,
                    signatures: signatures,
                    syncedFiles: &syncedFiles,
                    updatedSignatures: &signatures,
                    removedFiles: &removedFiles,
                    skippedEntries: &skippedEntries
                ) {
                    changedEntries.append(entry)
                }
            } else {
                for syncedPath in syncedFiles where syncedPath == changedPath || syncedPath.hasPrefix(changedPath + "/") {
                    removedFiles.insert(syncedPath)
                }
            }
        }

        for removed in removedFiles {
            syncedFiles.remove(removed)
            signatures.removeValue(forKey: removed)
        }

        try removeDeletedFiles(
            removedFiles.sorted(),
            volume: project.dockerVolume,
            guestPath: project.guestPath,
            helperContainer: helperContainer
        )
        if !changedEntries.isEmpty {
            if let helperContainer,
               try copyChangedEntriesToHelperFastPath(
                   changedEntries,
                   helperContainer: helperContainer,
                   guestPath: project.guestPath
               ) {
                // Small watch updates avoid staging and docker cp; larger batches use the bulk copy path.
            } else if try copyEntriesToVolumeTarStream(
                changedEntries,
                volume: project.dockerVolume,
                guestPath: project.guestPath
            ) {
                // Streaming through Docker stdin avoids a macOS bind-mounted staging directory.
            } else {
                let staging = try makeStagingDirectory()
                defer { try? FileManager.default.removeItem(at: staging) }
                try stage(entries: changedEntries, at: staging)
                try copyStagingToVolume(
                    staging,
                    volume: project.dockerVolume,
                    guestPath: project.guestPath,
                    helperContainer: helperContainer
                )
            }
        }
        try saveManifest(ConjetFSManifest(
            projectID: project.id,
            syncedFiles: syncedFiles.sorted(),
            fileSignatures: signatures
        ))

        let includedBytes = syncedFiles.reduce(Int64(0)) { total, path in
            total + (signatures[path]?.bytes ?? 0)
        }
        let changedBytes = changedEntries.reduce(Int64(0)) { $0 + $1.bytes }
        let skippedBytes = skippedEntries.reduce(Int64(0)) { $0 + $1.bytes }
        return ConjetFSSyncResult(
            project: project,
            dockerContext: dockerContext,
            guestPath: project.guestPath,
            includedFiles: syncedFiles.count,
            changedFiles: changedEntries.count,
            skippedFiles: skippedEntries.count,
            removedFiles: removedFiles.count,
            includedBytes: includedBytes,
            changedBytes: changedBytes,
            skippedBytes: skippedBytes,
            dockerVolume: project.dockerVolume,
            containerMountArgument: "\(project.dockerVolume):\(project.guestPath)"
        )
    }

    private func sync(plan: ConjetFSSyncPlan) throws -> ConjetFSSyncResult {
        let project = plan.project
        try removeDeletedFiles(plan.removedFiles, volume: project.dockerVolume, guestPath: project.guestPath)
        if !plan.changedFiles.isEmpty {
            if try copyEntriesToVolumeTarStream(
                plan.changedFiles,
                volume: project.dockerVolume,
                guestPath: project.guestPath
            ) {
                // Fast global path: stream host changes directly into the VM-native volume.
            } else {
                let staging = try makeStagingDirectory()
                defer { try? FileManager.default.removeItem(at: staging) }
                try stage(plan: plan, at: staging)
                try copyStagingToVolume(staging, volume: project.dockerVolume, guestPath: project.guestPath)
            }
        }
        try saveManifest(
            ConjetFSManifest(
                projectID: project.id,
                syncedFiles: plan.includedFiles.map(\.path).sorted(),
                fileSignatures: Dictionary(uniqueKeysWithValues: plan.includedFiles.map { ($0.path, $0.signature) })
            )
        )

        return ConjetFSSyncResult(
            project: project,
            dockerContext: dockerContext,
            guestPath: project.guestPath,
            includedFiles: plan.includedFiles.count,
            changedFiles: plan.changedFiles.count,
            skippedFiles: plan.skippedFiles.count,
            removedFiles: plan.removedFiles.count,
            includedBytes: plan.includedBytes,
            changedBytes: plan.changedBytes,
            skippedBytes: plan.skippedBytes,
            dockerVolume: project.dockerVolume,
            containerMountArgument: "\(project.dockerVolume):\(project.guestPath)"
        )
    }

    public func withSyncMountedRun(
        project: ConjetProject,
        run body: (ConjetFSRunPreparation) throws -> ProcessResult
    ) throws -> (sync: ConjetFSSyncResult, process: ProcessResult) {
        let plan = try makePlan(project: project)
        var mountArguments = [
            "--mount",
            "type=volume,source=\(project.dockerVolume),target=\(project.guestPath)"
        ]

        var preSynced = false
        if !plan.removedFiles.isEmpty {
            try removeDeletedFiles(plan.removedFiles, volume: project.dockerVolume, guestPath: project.guestPath)
            preSynced = true
        }

        var shellPrelude = "mkdir -p \(shellQuote(plan.project.guestPath))"
        var staging: URL?
        if !plan.changedFiles.isEmpty,
           plan.removedFiles.isEmpty,
           let inlinePrelude = try inlineTarExtractPrelude(
               entries: plan.changedFiles,
               guestPath: project.guestPath
           ) {
            shellPrelude = inlinePrelude
        } else if !plan.changedFiles.isEmpty,
           try copyEntriesToVolumeTarStream(
               plan.changedFiles,
               volume: project.dockerVolume,
               guestPath: project.guestPath
           ) {
            preSynced = true
        } else if !plan.changedFiles.isEmpty {
            let stagingDirectory = try makeStagingDirectory()
            try stage(plan: plan, at: stagingDirectory)
            staging = stagingDirectory
            mountArguments += [
                "--mount",
                "type=bind,source=\(stagingDirectory.path),target=/conjetfs-stage,readonly"
            ]
            shellPrelude = syncMountedRunPrelude(plan: plan)
        }
        defer {
            if let staging {
                try? FileManager.default.removeItem(at: staging)
            }
        }

        if preSynced {
            try saveManifest(
                ConjetFSManifest(
                    projectID: project.id,
                    syncedFiles: plan.includedFiles.map(\.path).sorted(),
                    fileSignatures: Dictionary(uniqueKeysWithValues: plan.includedFiles.map { ($0.path, $0.signature) })
                )
            )
        }

        let preparation = ConjetFSRunPreparation(
            sync: ConjetFSSyncResult(
                project: project,
                dockerContext: dockerContext,
                guestPath: project.guestPath,
                includedFiles: plan.includedFiles.count,
                changedFiles: plan.changedFiles.count,
                skippedFiles: plan.skippedFiles.count,
                removedFiles: plan.removedFiles.count,
                includedBytes: plan.includedBytes,
                changedBytes: plan.changedBytes,
                skippedBytes: plan.skippedBytes,
                dockerVolume: project.dockerVolume,
                containerMountArgument: "\(project.dockerVolume):\(project.guestPath)"
            ),
            dockerMountArguments: mountArguments,
            shellPrelude: shellPrelude
        )

        let process = try body(preparation)
        if process.succeeded && !preSynced {
            try saveManifest(
                ConjetFSManifest(
                    projectID: project.id,
                    syncedFiles: plan.includedFiles.map(\.path).sorted(),
                    fileSignatures: Dictionary(uniqueKeysWithValues: plan.includedFiles.map { ($0.path, $0.signature) })
                )
            )
        }
        return (preparation.sync, process)
    }

    public func status(project: ConjetProject) throws -> ConjetFSStatus {
        let plan = try makePlan(project: project)
        let manifest = try loadManifest(projectID: project.id)
        return ConjetFSStatus(
            project: project,
            dockerContext: dockerContext,
            guestPath: project.guestPath,
            dockerVolume: project.dockerVolume,
            hostSyncedFiles: plan.includedFiles.count,
            changedFiles: plan.changedFiles.count,
            removedFiles: plan.removedFiles.count,
            skippedFiles: plan.skippedFiles.count,
            hostSyncedBytes: plan.includedBytes,
            changedBytes: plan.changedBytes,
            skippedBytes: plan.skippedBytes,
            manifestUpdatedAt: manifest?.updatedAt,
            dirty: !plan.changedFiles.isEmpty || !plan.removedFiles.isEmpty
        )
    }

    public func export(project: ConjetProject, paths exportPaths: [String], to destination: URL) throws -> ConjetFSExportResult {
        let normalizedPaths = try exportPaths.map(normalizeExportPath)
        guard !normalizedPaths.isEmpty else {
            throw ConjetError.invalidArgument("sync export requires at least one path")
        }

        let destination = destination.standardizedFileURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try createVolume(project.dockerVolume)

        let containerName = "conjetfs-export-\(UUID().uuidString)"
        var created = false
        defer {
            if created {
                _ = try? runDocker(["rm", "-f", containerName])
            }
        }

        try requireSuccess(runDocker([
            "run", "-d",
            "--name", containerName,
            "--mount", "type=volume,source=\(project.dockerVolume),target=\(project.guestPath),readonly",
            "-w", project.guestPath,
            "alpine:3.20",
            "sh", "-c", "sleep 300"
        ]))
        created = true

        for path in normalizedPaths {
            try requireSuccess(runDocker([
                "cp",
                "\(containerName):\(project.guestPath)/\(path)",
                destination.path
            ]))
        }

        return ConjetFSExportResult(
            project: project,
            dockerContext: dockerContext,
            dockerVolume: project.dockerVolume,
            guestPath: project.guestPath,
            exportedPaths: normalizedPaths,
            hostDestination: destination.path
        )
    }

    public func startSyncHelper(project: ConjetProject) throws -> String {
        let containerName = "conjetfs-sync-\(UUID().uuidString)"
        try requireSuccess(runDocker([
            "run", "-d",
            "--name", containerName,
            "--mount", "type=volume,source=\(project.dockerVolume),target=\(project.guestPath)",
            "-w", project.guestPath,
            "alpine:3.20",
            "sh", "-c", "sleep 86400"
        ]))
        return containerName
    }

    public func stopSyncHelper(_ containerName: String) {
        _ = try? runDocker(["rm", "-f", containerName])
    }

    public static func defaultDockerContext(profileName: String) -> String {
        profileName == "default" ? "conjet" : "conjet-\(profileName)"
    }

    public static func projectMetadataDirectory(root: URL) -> URL {
        root.appendingPathComponent(".conjet", isDirectory: true)
    }

    public static func projectFile(root: URL) -> URL {
        projectMetadataDirectory(root: root).appendingPathComponent("project.json")
    }

    public static func volumeName(profileName: String, projectName: String, projectID: String) -> String {
        let profile = sanitizeDockerName(profileName)
        let name = sanitizeDockerName(projectName.isEmpty ? "workspace" : projectName)
        let suffix = String(projectID.prefix(12))
        return "conjetfs-\(profile)-\(name)-\(suffix)"
    }

    private func canonicalProjectRoot() throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConjetError.invalidArgument("project path does not exist or is not a directory: \(projectRoot.path)")
        }
        return projectRoot.standardizedFileURL
    }

    private func collectProjectPaths(root: URL) throws -> [String] {
        let manager = FileManager.default
        let classifier = PathClassifier(ignore: try Self.loadIgnore(root: root))
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        var collectedPaths: [String] = []
        let excludedRoots = [paths.rootHome, paths.home]
            .map { $0.standardizedFileURL.path }
        pathLoop: for case let url as URL in enumerator {
            let urlPath = url.standardizedFileURL.path
            for excludedRoot in excludedRoots where urlPath == excludedRoot || urlPath.hasPrefix(excludedRoot + "/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue pathLoop
            }

            let relativePath = relativePath(for: url, root: root)
            if relativePath == ".conjet" || relativePath.hasPrefix(".conjet/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
               values.isDirectory == true {
                let classification = classifier.classify(relativePath)
                if classification.placement == .ignored || classification.placement == .vmNative {
                    enumerator.skipDescendants()
                }
            }
            collectedPaths.append(relativePath)
        }
        return collectedPaths.sorted()
    }

    private func stage(plan: ConjetFSSyncPlan, at staging: URL) throws {
        try stage(entries: plan.changedFiles, at: staging)
    }

    private func stage(entries: [ConjetFSFileEntry], at staging: URL) throws {
        let root = try canonicalProjectRoot()
        let manager = FileManager.default
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        for entry in entries {
            let source = root.appendingPathComponent(entry.path)
            let destination = staging.appendingPathComponent(entry.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: source, to: destination)
        }
    }

    private func createVolume(_ name: String) throws {
        try requireSuccess(runDocker(["volume", "create", name]))
    }

    private func removeDeletedFiles(
        _ files: [String],
        volume: String,
        guestPath: String,
        helperContainer: String? = nil
    ) throws {
        guard !files.isEmpty else { return }
        let removalScript = files
            .map { "rm -f -- \(shellQuote($0))" }
            .joined(separator: "; ")
        let script = "cd \(shellQuote(guestPath)) && \(removalScript); find . -type d -empty -delete"
        if let helperContainer {
            try requireSuccess(runDocker([
                "exec", helperContainer,
                "sh", "-c", script
            ]))
            return
        }
        try requireSuccess(runDocker([
            "run", "--rm",
            "--mount", "type=volume,source=\(volume),target=\(guestPath)",
            "alpine:3.20",
            "sh", "-c", script
        ]))
    }

    private func copyStagingToVolume(
        _ staging: URL,
        volume: String,
        guestPath: String,
        helperContainer: String? = nil
    ) throws {
        if let helperContainer {
            try requireSuccess(runDocker([
                "cp",
                staging.appendingPathComponent(".").path,
                "\(helperContainer):\(guestPath)"
            ]))
            return
        }

        let fastCopyResult = try runDocker([
            "run", "--rm",
            "--mount", "type=bind,source=\(staging.path),target=/conjetfs-stage,readonly",
            "--mount", "type=volume,source=\(volume),target=\(guestPath)",
            "alpine:3.20",
            "sh", "-c", "mkdir -p \(shellQuote(guestPath)) && cp -a /conjetfs-stage/. \(shellQuote(guestPath))/"
        ])
        if fastCopyResult.succeeded {
            return
        }
        if fastCopyResult.stderr.contains("bind source path does not exist") ||
            fastCopyResult.stdout.contains("bind source path does not exist") {
            try copyStagingToVolumeWithDockerCP(staging, volume: volume, guestPath: guestPath)
            return
        }
        try requireSuccess(fastCopyResult)
    }

    private func copyEntriesToVolumeTarStream(
        _ entries: [ConjetFSFileEntry],
        volume: String,
        guestPath: String
    ) throws -> Bool {
        guard !entries.isEmpty else { return true }
        guard let archive = try makeTarArchive(entries: entries) else {
            return false
        }
        let result = try inputRunner(
            dockerExecutable,
            [
                "docker", "--context", dockerContext,
                "run", "--rm", "-i",
                "--mount", "type=volume,source=\(volume),target=\(guestPath)",
                "alpine:3.20",
                "sh", "-c", "mkdir -p \(shellQuote(guestPath)) && tar -xpf - -C \(shellQuote(guestPath))"
            ],
            archive
        )
        return result.succeeded
    }

    private func inlineTarExtractPrelude(
        entries: [ConjetFSFileEntry],
        guestPath: String
    ) throws -> String? {
        guard !entries.isEmpty else { return nil }
        let maxInlineFiles = 16
        let maxInlineArchiveBytes = 64 * 1024
        guard entries.count <= maxInlineFiles,
              let archive = try makeTarArchive(entries: entries),
              archive.count <= maxInlineArchiveBytes else {
            return nil
        }

        let encoded = archive.base64EncodedString(options: [.lineLength76Characters])
        return """
        mkdir -p \(shellQuote(guestPath)) && tmp="${TMPDIR:-/tmp}/conjetfs-sync-$$.tar.b64" && cat > "$tmp" <<'CONJETFS_TAR'
        \(encoded)
        CONJETFS_TAR
        base64 -d < "$tmp" | tar -xpf - -C \(shellQuote(guestPath)); conjetfs_status=$?; rm -f "$tmp"; test "$conjetfs_status" -eq 0
        """
    }

    private func makeTarArchive(entries: [ConjetFSFileEntry]) throws -> Data? {
        let root = try canonicalProjectRoot()
        var archive = Data()
        var directories: Set<String> = []

        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            for index in 0..<(parts.count - 1) {
                directories.insert(parts[0...index].joined(separator: "/") + "/")
            }
        }

        let directoryMode = 0o755
        let directoryModifiedAt = Int64(Date().timeIntervalSince1970)
        for directory in directories.sorted() {
            guard appendTarHeader(
                path: directory,
                mode: directoryMode,
                size: 0,
                modifiedAt: directoryModifiedAt,
                typeFlag: Self.tarDirectoryTypeFlag,
                linkName: "",
                to: &archive
            ) else {
                return nil
            }
        }

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let source = root.appendingPathComponent(entry.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let fileType = attributes[.type] as? FileAttributeType
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let modifiedAt = entry.signature.modifiedAtNanoseconds > 0
                ? entry.signature.modifiedAtNanoseconds / 1_000_000_000
                : Int64(Date().timeIntervalSince1970)

            if fileType == .typeSymbolicLink {
                let linkName = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                guard appendTarHeader(
                    path: entry.path,
                    mode: mode,
                    size: 0,
                    modifiedAt: modifiedAt,
                    typeFlag: Self.tarSymlinkTypeFlag,
                    linkName: linkName,
                    to: &archive
                ) else {
                    return nil
                }
                continue
            }

            guard fileType == .typeRegular else {
                return nil
            }

            let data = try Data(contentsOf: source)
            guard appendTarHeader(
                path: entry.path,
                mode: mode,
                size: Int64(data.count),
                modifiedAt: modifiedAt,
                typeFlag: Self.tarRegularFileTypeFlag,
                linkName: "",
                to: &archive
            ) else {
                return nil
            }
            archive.append(data)
            archive.append(Data(repeating: 0, count: Self.tarPadding(for: data.count)))
        }

        archive.append(Data(repeating: 0, count: Self.tarBlockSize * 2))
        return archive
    }

    private func appendTarHeader(
        path: String,
        mode: Int,
        size: Int64,
        modifiedAt: Int64,
        typeFlag: UInt8,
        linkName: String,
        to archive: inout Data
    ) -> Bool {
        guard let pathParts = Self.tarPathParts(path),
              linkName.utf8.count <= 100 else {
            return false
        }

        var header = [UInt8](repeating: 0, count: Self.tarBlockSize)
        guard Self.writeTarString(pathParts.name, into: &header, offset: 0, length: 100),
              Self.writeTarOctal(Int64(mode & 0o7777), into: &header, offset: 100, length: 8),
              Self.writeTarOctal(0, into: &header, offset: 108, length: 8),
              Self.writeTarOctal(0, into: &header, offset: 116, length: 8),
              Self.writeTarOctal(size, into: &header, offset: 124, length: 12),
              Self.writeTarOctal(modifiedAt, into: &header, offset: 136, length: 12),
              Self.writeTarString(linkName, into: &header, offset: 157, length: 100),
              Self.writeTarString("ustar", into: &header, offset: 257, length: 6),
              Self.writeTarString("00", into: &header, offset: 263, length: 2),
              Self.writeTarString(pathParts.prefix, into: &header, offset: 345, length: 155) else {
            return false
        }

        header[156] = typeFlag
        for index in 148..<156 {
            header[index] = Self.tarSpace
        }
        let checksum = header.reduce(0) { $0 + Int($1) }
        let checksumText = String(checksum, radix: 8)
        guard checksumText.count <= 6 else {
            return false
        }
        let paddedChecksum = String(repeating: "0", count: 6 - checksumText.count) + checksumText
        let checksumBytes = Array(paddedChecksum.utf8)
        for index in 0..<checksumBytes.count {
            header[148 + index] = checksumBytes[index]
        }
        header[154] = 0
        header[155] = Self.tarSpace

        archive.append(contentsOf: header)
        return true
    }

    private func copyChangedEntriesToHelperFastPath(
        _ entries: [ConjetFSFileEntry],
        helperContainer: String,
        guestPath: String
    ) throws -> Bool {
        guard streamingHelperFastPath else {
            return false
        }
        let maxFastPathFiles = 8
        let maxFastPathBytes: Int64 = 512 * 1024
        guard entries.count <= maxFastPathFiles,
              entries.reduce(Int64(0), { $0 + $1.bytes }) <= maxFastPathBytes else {
            return false
        }

        let root = try canonicalProjectRoot()
        let manager = FileManager.default
        for entry in entries {
            let source = root.appendingPathComponent(entry.path)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                return false
            }
            guard manager.fileExists(atPath: source.path) else {
                return false
            }
        }

        for entry in entries {
            let source = root.appendingPathComponent(entry.path)
            let data = try Data(contentsOf: source)
            let mode = try Self.octalPermissions(for: source)
            let target = joinGuestPath(guestPath, entry.path)
            let script = [
                "set -eu",
                "target=\(shellQuote(target))",
                "mkdir -p \"$(dirname \"$target\")\"",
                "tmp=\"${target}.conjet-tmp-$$\"",
                "cat > \"$tmp\"",
                "chmod \(mode) \"$tmp\"",
                "mv -f \"$tmp\" \"$target\""
            ].joined(separator: "; ")
            try requireSuccess(inputRunner(
                dockerExecutable,
                ["docker", "--context", dockerContext, "exec", "-i", helperContainer, "sh", "-c", script],
                data
            ))
        }
        return true
    }

    private func syncMountedRunPrelude(plan: ConjetFSSyncPlan) -> String {
        var commands: [String] = ["mkdir -p \(shellQuote(plan.project.guestPath))"]
        if !plan.removedFiles.isEmpty {
            let removalScript = plan.removedFiles
                .map { "rm -f -- \(shellQuote($0))" }
                .joined(separator: "; ")
            commands.append("cd \(shellQuote(plan.project.guestPath)) && \(removalScript); find . -type d -empty -delete")
        }
        if !plan.changedFiles.isEmpty {
            commands.append("cp -a /conjetfs-stage/. \(shellQuote(plan.project.guestPath))/")
        }
        return commands.joined(separator: " && ")
    }

    private func makeStagingDirectory() throws -> URL {
        let root = try canonicalProjectRoot()
        return Self.projectMetadataDirectory(root: root)
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
    }

    private func copyStagingToVolumeWithDockerCP(_ staging: URL, volume: String, guestPath: String) throws {
        let containerName = "conjetfs-\(UUID().uuidString)"
        var created = false
        defer {
            if created {
                _ = try? runDocker(["rm", "-f", containerName])
            }
        }

        try requireSuccess(runDocker([
            "run", "-d",
            "--name", containerName,
            "--mount", "type=volume,source=\(volume),target=\(guestPath)",
            "-w", guestPath,
            "alpine:3.20",
            "sh", "-c", "sleep 300"
        ]))
        created = true
        try requireSuccess(runDocker([
            "cp",
            staging.appendingPathComponent(".").path,
            "\(containerName):\(guestPath)"
        ]))
    }

    private func runDocker(_ arguments: [String]) throws -> ProcessResult {
        try runner(dockerExecutable, ["docker", "--context", dockerContext] + arguments)
    }

    private func joinGuestPath(_ guestPath: String, _ relativePath: String) -> String {
        let base = guestPath.hasSuffix("/") ? String(guestPath.dropLast()) : guestPath
        return "\(base)/\(relativePath)"
    }

    private func requireSuccess(_ result: ProcessResult) throws {
        guard result.succeeded else {
            throw ConjetError.processFailed(
                executable: result.executable,
                exitCode: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    private func manifestFile(projectID: String) -> URL {
        paths.stateDirectory
            .appendingPathComponent("conjetfs", isDirectory: true)
            .appendingPathComponent("\(projectID).manifest.json")
    }

    private func loadManifest(projectID: String) throws -> ConjetFSManifest? {
        let url = manifestFile(projectID: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ConjetFSManifest.self, from: data)
    }

    private func saveManifest(_ manifest: ConjetFSManifest) throws {
        let url = manifestFile(projectID: manifest.projectID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.conjetPretty.encode(manifest).write(to: url, options: .atomic)
    }

    private func normalizeChangedPaths(_ rawPaths: [String]) throws -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for rawPath in rawPaths {
            let normalized = normalizePath(rawPath)
            let components = normalized.split(separator: "/").map(String.init)
            guard !normalized.isEmpty, !components.contains("..") else {
                throw ConjetError.invalidArgument("invalid changed path '\(rawPath)'")
            }
            if !seen.contains(normalized) {
                seen.insert(normalized)
                paths.append(normalized)
            }
        }
        return paths.sorted()
    }

    private func detectProjectKinds(root: URL) throws -> [ProjectKind] {
        let markers = [
            "package.json", "pnpm-lock.yaml", "package-lock.json", "yarn.lock",
            "composer.json", "composer.lock",
            "Cargo.toml", "Cargo.lock",
            "go.mod", "go.sum",
            "pyproject.toml", "uv.lock", "poetry.lock", "requirements.txt",
            "pom.xml", "build.gradle", "gradle.lockfile"
        ].filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        return ProjectDetector.detect(files: markers).kinds
    }

    private func collectChangedEntries(
        root: URL,
        relativeRoot: String,
        classifier: PathClassifier,
        projectKinds: [ProjectKind],
        signatures: [String: ConjetFSFileSignature],
        syncedFiles: inout Set<String>,
        updatedSignatures: inout [String: ConjetFSFileSignature],
        removedFiles: inout Set<String>,
        skippedEntries: inout [ConjetFSFileEntry]
    ) throws -> [ConjetFSFileEntry] {
        let directory = root.appendingPathComponent(relativeRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        var entries: [ConjetFSFileEntry] = []
        for case let url as URL in enumerator {
            let relativePath = self.relativePath(for: url, root: root)
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                let classification = classifier.classify(relativePath, projectKinds: projectKinds)
                if classification.placement == .ignored || classification.placement == .vmNative {
                    skippedEntries.append(ConjetFSFileEntry(path: relativePath, bytes: 0, classification: classification))
                    enumerator.skipDescendants()
                }
                continue
            }
            if let entry = try changedEntry(
                root: root,
                relativePath: relativePath,
                classifier: classifier,
                projectKinds: projectKinds,
                signatures: signatures,
                syncedFiles: &syncedFiles,
                updatedSignatures: &updatedSignatures,
                removedFiles: &removedFiles,
                skippedEntries: &skippedEntries
            ) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func changedEntry(
        root: URL,
        relativePath: String,
        classifier: PathClassifier,
        projectKinds: [ProjectKind],
        signatures: [String: ConjetFSFileSignature],
        syncedFiles: inout Set<String>,
        updatedSignatures: inout [String: ConjetFSFileSignature],
        removedFiles: inout Set<String>,
        skippedEntries: inout [ConjetFSFileEntry]
    ) throws -> ConjetFSFileEntry? {
        let fileURL = root.appendingPathComponent(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else {
            return nil
        }

        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let classification = classifier.classify(relativePath, projectKinds: projectKinds)
        let signature = Self.signature(bytes: bytes, attributes: attributes)
        let entry = ConjetFSFileEntry(
            path: relativePath,
            bytes: bytes,
            classification: classification,
            signature: signature
        )

        switch classification.placement {
        case .hostSynced, .lazySynced:
            syncedFiles.insert(relativePath)
            updatedSignatures[relativePath] = signature
            removedFiles.remove(relativePath)
            guard signatures[relativePath] != signature else {
                return nil
            }
            return entry
        case .vmNative, .ignored, .exportOnDemand:
            skippedEntries.append(entry)
            if syncedFiles.contains(relativePath) {
                removedFiles.insert(relativePath)
            }
            return nil
        }
    }

    private static func signature(bytes: Int64, attributes: [FileAttributeKey: Any]) -> ConjetFSFileSignature {
        let modified = attributes[.modificationDate] as? Date
        let modifiedAtNanoseconds = modified
            .map { Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded()) }
            ?? 0
        return ConjetFSFileSignature(bytes: bytes, modifiedAtNanoseconds: modifiedAtNanoseconds)
    }

    private static func octalPermissions(for url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let rawMode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        return String(format: "%04o", rawMode & 0o777)
    }

    private func normalizeExportPath(_ path: String) throws -> String {
        let normalized = normalizePath(path)
        let components = normalized.split(separator: "/").map(String.init)
        guard !normalized.isEmpty, !components.contains("..") else {
            throw ConjetError.invalidArgument("invalid export path '\(path)'")
        }
        return normalized
    }

    private func relativePath(for url: URL, root: URL) -> String {
        for candidateRoot in [root, root.resolvingSymlinksInPath(), root.standardizedFileURL] {
            let rootPath = candidateRoot.path.hasSuffix("/") ? candidateRoot.path : candidateRoot.path + "/"
            let pathCandidates = [
                url.path,
                url.resolvingSymlinksInPath().path,
                url.standardizedFileURL.path
            ]
            if let path = pathCandidates.first(where: { $0.hasPrefix(rootPath) }) {
                return normalizePath(String(path.dropFirst(rootPath.count)))
            }
        }
        return normalizePath(url.lastPathComponent)
    }

    public static func loadIgnore(root: URL) throws -> ConjetIgnore {
        var rules = IgnoreRule.defaultRules
        rules.append(IgnoreRule(pattern: ".conjet/"))
        for fileName in [".conjetignore", ".dockerignore", ".gitignore"] {
            let url = root.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let parsed = ConjetIgnore.parse(try String(contentsOf: url, encoding: .utf8))
            rules.append(contentsOf: parsed.rules)
        }
        return ConjetIgnore(rules: rules)
    }

    private static func projectID(for rootPath: String) -> String {
        let hash = fnv1a64(rootPath)
        return String(format: "%016llx", hash)
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func sanitizeDockerName(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let mapped = String(value.map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
            .lowercased()
        return mapped.isEmpty ? "workspace" : String(mapped.prefix(48))
    }

    private static let tarBlockSize = 512
    private static let tarSpace = UInt8(ascii: " ")
    private static let tarRegularFileTypeFlag = UInt8(ascii: "0")
    private static let tarDirectoryTypeFlag = UInt8(ascii: "5")
    private static let tarSymlinkTypeFlag = UInt8(ascii: "2")

    private static func tarPadding(for count: Int) -> Int {
        let remainder = count % tarBlockSize
        return remainder == 0 ? 0 : tarBlockSize - remainder
    }

    private static func tarPathParts(_ rawPath: String) -> (name: String, prefix: String)? {
        let path = normalizePath(rawPath)
        if path.utf8.count <= 100 {
            return (path, "")
        }
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else {
            return nil
        }
        for index in 1..<components.count {
            let prefix = components[0..<index].joined(separator: "/")
            let name = components[index..<components.count].joined(separator: "/")
            if prefix.utf8.count <= 155 && name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        return nil
    }

    private static func writeTarString(
        _ value: String,
        into header: inout [UInt8],
        offset: Int,
        length: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count <= length else {
            return false
        }
        for index in 0..<bytes.count {
            header[offset + index] = bytes[index]
        }
        return true
    }

    private static func writeTarOctal(
        _ value: Int64,
        into header: inout [UInt8],
        offset: Int,
        length: Int
    ) -> Bool {
        guard value >= 0 else {
            return false
        }
        let text = String(value, radix: 8)
        guard text.count < length else {
            return false
        }
        let padded = String(repeating: "0", count: length - 1 - text.count) + text
        let bytes = Array(padded.utf8)
        for index in 0..<bytes.count {
            header[offset + index] = bytes[index]
        }
        header[offset + length - 1] = 0
        return true
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static let defaultConjetIgnore = """
    # ConjetFS already keeps dependency and build churn in VM-native storage.
    # Add project-specific files here only when they should be ignored entirely.
    *.log
    *.tmp
    """
}

private extension JSONEncoder {
    static var conjetPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
