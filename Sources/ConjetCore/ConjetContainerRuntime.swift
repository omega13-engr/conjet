import Foundation

public struct ConjetOCIConfig: Codable, Equatable, Sendable {
    public var ociVersion: String
    public var process: ConjetOCIProcess?
    public var root: ConjetOCIRoot?
    public var mounts: [ConjetOCIMount]?
    public var hooks: ConjetOCIHooks?
    public var annotations: [String: String]?

    public init(
        ociVersion: String,
        process: ConjetOCIProcess?,
        root: ConjetOCIRoot?,
        mounts: [ConjetOCIMount]? = nil,
        hooks: ConjetOCIHooks? = nil,
        annotations: [String: String]? = nil
    ) {
        self.ociVersion = ociVersion
        self.process = process
        self.root = root
        self.mounts = mounts
        self.hooks = hooks
        self.annotations = annotations
    }
}

public struct ConjetOCIProcess: Codable, Equatable, Sendable {
    public var args: [String]?
    public var env: [String]?
    public var cwd: String?
    public var terminal: Bool?
    public var user: ConjetOCIUser?

    public init(
        args: [String]?,
        env: [String]? = nil,
        cwd: String? = nil,
        terminal: Bool? = nil,
        user: ConjetOCIUser? = nil
    ) {
        self.args = args
        self.env = env
        self.cwd = cwd
        self.terminal = terminal
        self.user = user
    }
}

public struct ConjetOCIUser: Codable, Equatable, Sendable {
    public var uid: UInt32?
    public var gid: UInt32?

    public init(uid: UInt32? = nil, gid: UInt32? = nil) {
        self.uid = uid
        self.gid = gid
    }
}

public struct ConjetOCIRoot: Codable, Equatable, Sendable {
    public var path: String
    public var readonly: Bool?

    public init(path: String, readonly: Bool? = nil) {
        self.path = path
        self.readonly = readonly
    }
}

public struct ConjetOCIMount: Codable, Equatable, Sendable {
    public var destination: String
    public var type: String?
    public var source: String?
    public var options: [String]?

    public init(destination: String, type: String? = nil, source: String? = nil, options: [String]? = nil) {
        self.destination = destination
        self.type = type
        self.source = source
        self.options = options
    }
}

public struct ConjetOCIHooks: Codable, Equatable, Sendable {
    public var prestart: [ConjetOCIHook]?
    public var createRuntime: [ConjetOCIHook]?
    public var createContainer: [ConjetOCIHook]?
    public var startContainer: [ConjetOCIHook]?
    public var poststart: [ConjetOCIHook]?
    public var poststop: [ConjetOCIHook]?
}

public struct ConjetOCIHook: Codable, Equatable, Sendable {
    public var path: String
    public var args: [String]?
    public var env: [String]?
    public var timeout: Int?
}

public struct ConjetDirectOCILaunchSpec: Codable, Equatable, Sendable {
    public var bundlePath: String
    public var rootfsPath: String
    public var args: [String]
    public var environment: [String]
    public var workingDirectory: String
    public var readonlyRootfs: Bool
    public var mounts: [ConjetOCIMount]
    public var kernelArguments: [String]

    public init(
        bundlePath: String,
        rootfsPath: String,
        args: [String],
        environment: [String],
        workingDirectory: String,
        readonlyRootfs: Bool,
        mounts: [ConjetOCIMount],
        kernelArguments: [String]
    ) {
        self.bundlePath = bundlePath
        self.rootfsPath = rootfsPath
        self.args = args
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.readonlyRootfs = readonlyRootfs
        self.mounts = mounts
        self.kernelArguments = kernelArguments
    }

    public func kernelCommandLine(appendingTo base: String) -> String {
        let suffix = kernelArguments.joined(separator: " ")
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suffix : "\(trimmed) \(suffix)"
    }
}

public enum ConjetDirectOCIBundleLoader {
    public static func load(bundleURL: URL) throws -> ConjetDirectOCILaunchSpec {
        let standardizedBundle = bundleURL.standardizedFileURL
        let configURL = standardizedBundle.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ConjetError.filesystem("OCI bundle is missing config.json at \(configURL.path)")
        }
        let config = try ConjetJSON.decoder().decode(ConjetOCIConfig.self, from: Data(contentsOf: configURL))
        return try validate(config, bundleURL: standardizedBundle)
    }

    public static func validate(_ config: ConjetOCIConfig, bundleURL: URL) throws -> ConjetDirectOCILaunchSpec {
        guard config.ociVersion.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("1.") else {
            throw ConjetError.invalidArgument("direct OCI requires OCI runtime spec 1.x")
        }
        guard config.hooks == nil else {
            throw ConjetError.unavailable("direct OCI does not support OCI hooks")
        }
        guard let root = config.root else {
            throw ConjetError.invalidArgument("direct OCI bundle is missing root")
        }
        guard let process = config.process else {
            throw ConjetError.invalidArgument("direct OCI bundle is missing process")
        }
        guard let args = process.args, !args.isEmpty else {
            throw ConjetError.invalidArgument("direct OCI process.args must not be empty")
        }
        guard args.count <= 32 else {
            throw ConjetError.invalidArgument("direct OCI supports at most 32 process arguments")
        }
        for argument in args {
            try validateKernelArgument(argument, label: "process argument")
        }
        guard args[0].hasPrefix("/") else {
            throw ConjetError.invalidArgument("direct OCI process.args[0] must be an absolute guest path")
        }
        let cwd = process.cwd ?? "/"
        guard cwd.hasPrefix("/") else {
            throw ConjetError.invalidArgument("direct OCI process.cwd must be absolute")
        }
        let env = process.env ?? []
        for entry in env {
            guard !entry.isEmpty,
                  entry.contains("="),
                  !entry.utf8.contains(0) else {
                throw ConjetError.invalidArgument("direct OCI process.env contains an invalid entry")
            }
        }
        if process.terminal == true {
            throw ConjetError.unavailable("direct OCI does not support terminal=true yet")
        }

        let rootfsURL = try resolveRootfs(root.path, bundleURL: bundleURL)
        let mounts = config.mounts ?? []
        try validateMounts(mounts)

        var kernelArguments = ["conjet.argc=\(args.count)"]
        for (index, argument) in args.enumerated() {
            kernelArguments.append("conjet.arg\(index)=\(percentEncodeKernelValue(argument))")
        }
        kernelArguments.append("conjet.cwd=\(percentEncodeKernelValue(cwd))")

        return ConjetDirectOCILaunchSpec(
            bundlePath: bundleURL.path,
            rootfsPath: rootfsURL.path,
            args: args,
            environment: env,
            workingDirectory: cwd,
            readonlyRootfs: root.readonly ?? true,
            mounts: mounts,
            kernelArguments: kernelArguments
        )
    }

    public static func percentEncodeKernelValue(_ value: String) -> String {
        var output = ""
        for byte in value.utf8 {
            if (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a)
                || byte == 0x2f
                || byte == 0x2d
                || byte == 0x2e
                || byte == 0x5f
                || byte == 0x3a {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    private static func validateKernelArgument(_ value: String, label: String) throws {
        guard !value.isEmpty else {
            throw ConjetError.invalidArgument("direct OCI \(label) must not be empty")
        }
        guard value.utf8.count <= 1024 else {
            throw ConjetError.invalidArgument("direct OCI \(label) is too long")
        }
        guard !value.utf8.contains(0) else {
            throw ConjetError.invalidArgument("direct OCI \(label) contains NUL")
        }
    }

    private static func resolveRootfs(_ rootPath: String, bundleURL: URL) throws -> URL {
        guard !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConjetError.invalidArgument("direct OCI root.path must not be empty")
        }
        let rootfsURL: URL
        if rootPath.hasPrefix("/") {
            rootfsURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        } else {
            rootfsURL = bundleURL.appendingPathComponent(rootPath).standardizedFileURL
            guard rootfsURL.path == bundleURL.appendingPathComponent(rootPath).standardizedFileURL.path,
                  rootfsURL.path.hasPrefix(bundleURL.path + "/") else {
                throw ConjetError.invalidArgument("direct OCI root.path must stay inside the bundle")
            }
        }
        guard FileManager.default.fileExists(atPath: rootfsURL.path) else {
            throw ConjetError.filesystem("direct OCI rootfs does not exist at \(rootfsURL.path)")
        }
        return rootfsURL
    }

    private static func validateMounts(_ mounts: [ConjetOCIMount]) throws {
        for mount in mounts {
            guard mount.destination.hasPrefix("/") else {
                throw ConjetError.invalidArgument("direct OCI mount destination must be absolute")
            }
            let type = mount.type ?? "bind"
            switch type {
            case "proc":
                guard mount.destination == "/proc" else {
                    throw ConjetError.unavailable("direct OCI proc mount must target /proc")
                }
            case "sysfs":
                guard mount.destination == "/sys" else {
                    throw ConjetError.unavailable("direct OCI sysfs mount must target /sys")
                }
            case "tmpfs":
                guard ["/dev", "/run", "/tmp"].contains(mount.destination) else {
                    throw ConjetError.unavailable("direct OCI tmpfs mount target is unsupported: \(mount.destination)")
                }
            case "bind":
                guard mount.options?.contains("ro") == true else {
                    throw ConjetError.unavailable("direct OCI bind mounts must be read-only in Pulse")
                }
            default:
                throw ConjetError.unavailable("direct OCI mount type is unsupported: \(type)")
            }
        }
    }
}
