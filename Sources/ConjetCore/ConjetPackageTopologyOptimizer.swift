import Foundation

public enum ConjetPackageManager: String, Codable, Equatable, Sendable {
    case pnpm
    case npm
    case yarn
    case composer
    case cargo
    case go
    case unknown
}

public struct ConjetPackageTopologyPlan: Codable, Equatable, Sendable {
    public var manager: ConjetPackageManager
    public var environment: [String: String]

    public init(manager: ConjetPackageManager, environment: [String: String]) {
        self.manager = manager
        self.environment = environment
    }

    public func dockerEnvironmentArguments() -> [String] {
        environment
            .sorted { $0.key < $1.key }
            .flatMap { ["--env", "\($0.key)=\($0.value)"] }
    }
}

public enum ConjetPackageTopologyOptimizer {
    public static func plan(projectRoot: URL, guestPath: String = "/workspace") -> ConjetPackageTopologyPlan {
        let manager = detectPackageManager(projectRoot: projectRoot)
        return plan(manager: manager, guestPath: guestPath)
    }

    public static func plan(manager: ConjetPackageManager, guestPath: String = "/workspace") -> ConjetPackageTopologyPlan {
        let guestPath = normalizeGuestPath(guestPath)
        switch manager {
        case .pnpm:
            return ConjetPackageTopologyPlan(manager: manager, environment: [
                "COREPACK_HOME": "\(guestPath)/.corepack-cache",
                "NPM_CONFIG_CACHE": "\(guestPath)/.npm-cache",
                "NPM_CONFIG_STORE_DIR": "\(guestPath)/.pnpm-store",
                "PNPM_HOME": "\(guestPath)/.pnpm-state"
            ])
        case .npm:
            return ConjetPackageTopologyPlan(manager: manager, environment: [
                "NPM_CONFIG_CACHE": "\(guestPath)/.npm-cache"
            ])
        case .yarn:
            return ConjetPackageTopologyPlan(manager: manager, environment: [
                "YARN_CACHE_FOLDER": "\(guestPath)/.yarn-cache"
            ])
        case .composer:
            return ConjetPackageTopologyPlan(manager: manager, environment: [
                "COMPOSER_CACHE_DIR": "\(guestPath)/.composer-cache"
            ])
        case .cargo:
            return ConjetPackageTopologyPlan(manager: manager, environment: [
                "CARGO_HOME": "\(guestPath)/.cargo-home",
                "CARGO_TARGET_DIR": "\(guestPath)/target"
            ])
        case .go:
            return ConjetPackageTopologyPlan(manager: manager, environment: [
                "GOCACHE": "\(guestPath)/.go/cache",
                "GOMODCACHE": "\(guestPath)/.go/pkg/mod"
            ])
        case .unknown:
            return ConjetPackageTopologyPlan(manager: manager, environment: [:])
        }
    }

    public static func detectPackageManager(projectRoot: URL) -> ConjetPackageManager {
        let root = projectRoot.standardizedFileURL
        let manager = FileManager.default
        let orderedMarkers: [(String, ConjetPackageManager)] = [
            ("pnpm-lock.yaml", .pnpm),
            ("package-lock.json", .npm),
            ("yarn.lock", .yarn),
            ("composer.lock", .composer),
            ("Cargo.lock", .cargo),
            ("go.mod", .go),
            ("package.json", .npm),
            ("composer.json", .composer),
            ("Cargo.toml", .cargo)
        ]

        for (marker, packageManager) in orderedMarkers {
            if manager.fileExists(atPath: root.appendingPathComponent(marker).path) {
                return packageManager
            }
        }
        return .unknown
    }

    private static func normalizeGuestPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/workspace" : "/" + trimmed
    }
}
