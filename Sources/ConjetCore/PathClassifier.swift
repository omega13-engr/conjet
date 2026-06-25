import Foundation

public enum PathPlacement: String, Codable, Equatable, Sendable {
    case hostSynced = "host-synced"
    case vmNative = "vm-native"
    case lazySynced = "lazy-synced"
    case ignored
    case exportOnDemand = "export-on-demand"
}

public enum ProjectKind: String, Codable, CaseIterable, Equatable, Sendable {
    case node
    case php
    case rust
    case go
    case python
    case java
    case unknown
}

public struct PathClassification: Codable, Equatable, Sendable {
    public var path: String
    public var placement: PathPlacement
    public var score: Int
    public var reason: String

    public init(path: String, placement: PathPlacement, score: Int, reason: String) {
        self.path = path
        self.placement = placement
        self.score = score
        self.reason = reason
    }
}

public struct ProjectFingerprint: Codable, Equatable, Sendable {
    public var files: [String]
    public var kinds: [ProjectKind]

    public init(files: [String], kinds: [ProjectKind]) {
        self.files = files
        self.kinds = kinds
    }
}

public enum ProjectDetector {
    public static func detect(files: [String]) -> ProjectFingerprint {
        let normalized = Set(files.map(normalizePath))
        var kinds: [ProjectKind] = []
        if normalized.contains("package.json") || normalized.contains("pnpm-lock.yaml")
            || normalized.contains("package-lock.json") || normalized.contains("yarn.lock") {
            kinds.append(.node)
        }
        if normalized.contains("composer.json") || normalized.contains("composer.lock") {
            kinds.append(.php)
        }
        if normalized.contains("Cargo.toml") || normalized.contains("Cargo.lock") {
            kinds.append(.rust)
        }
        if normalized.contains("go.mod") || normalized.contains("go.sum") {
            kinds.append(.go)
        }
        if normalized.contains("pyproject.toml") || normalized.contains("uv.lock")
            || normalized.contains("poetry.lock") || normalized.contains("requirements.txt") {
            kinds.append(.python)
        }
        if normalized.contains("pom.xml") || normalized.contains("build.gradle")
            || normalized.contains("gradle.lockfile") {
            kinds.append(.java)
        }
        if kinds.isEmpty {
            kinds.append(.unknown)
        }
        return ProjectFingerprint(files: Array(normalized).sorted(), kinds: kinds)
    }
}

public struct PathClassifier: Sendable {
    public var ignore: ConjetIgnore

    public init(ignore: ConjetIgnore = ConjetIgnore()) {
        self.ignore = ignore
    }

    public func classify(_ rawPath: String, projectKinds: [ProjectKind] = [.unknown]) -> PathClassification {
        let path = normalizePath(rawPath)
        let components = path.split(separator: "/").map(String.init)
        let base = components.last ?? path

        if ignore.isIgnored(path) {
            return PathClassification(path: path, placement: .ignored, score: -100, reason: "matched ignore policy")
        }

        if containsAnyComponent(components, vmNativeComponents(projectKinds: projectKinds)) {
            return PathClassification(path: path, placement: .vmNative, score: -80, reason: "dependency, cache, or build output stays on native Linux storage")
        }

        if containsAnyComponent(components, ignoredComponents) || ignoredSuffixes.contains(where: { base.hasSuffix($0) }) {
            return PathClassification(path: path, placement: .ignored, score: -90, reason: "temporary or noisy generated path")
        }

        if containsAnyComponent(components, lazySyncedComponents) {
            return PathClassification(path: path, placement: .lazySynced, score: -25, reason: "generated artifact is synced only when useful to inspect")
        }

        if exportOnDemandComponents.contains(base) || containsAnyComponent(components, exportOnDemandComponents) {
            return PathClassification(path: path, placement: .exportOnDemand, score: -40, reason: "large output should be exported explicitly")
        }

        if hostSyncedFileNames.contains(base) || sourceLikeFirstComponents.contains(components.first ?? "") {
            return PathClassification(path: path, placement: .hostSynced, score: 80, reason: "source or project metadata is host-authoritative")
        }

        if base.hasSuffix(".lock") || base.hasSuffix(".toml") || base.hasSuffix(".json")
            || base.hasSuffix(".yaml") || base.hasSuffix(".yml") {
            return PathClassification(path: path, placement: .hostSynced, score: 55, reason: "configuration and lockfiles are host-authoritative")
        }

        return PathClassification(path: path, placement: .hostSynced, score: 10, reason: "default conservative source-of-truth policy")
    }

    private func vmNativeComponents(projectKinds: [ProjectKind]) -> Set<String> {
        var components: Set<String> = [
            "node_modules", "vendor", "target", "dist", ".next", ".turbo", ".cache",
            ".gradle", "build", "coverage", ".pytest_cache", "__pycache__",
            ".venv", "venv", ".mypy_cache", ".ruff_cache", "tmp", "temp"
        ]
        if projectKinds.contains(.go) {
            components.formUnion(["pkg/mod", "bin"])
        }
        return components
    }

    private func containsAnyComponent(_ components: [String], _ candidates: Set<String>) -> Bool {
        for candidate in candidates {
            if candidate.contains("/") {
                let candidateComponents = candidate.split(separator: "/").map(String.init)
                if componentsContainsSubsequence(components, candidateComponents) {
                    return true
                }
            } else if components.contains(candidate) {
                return true
            }
        }
        return false
    }

    private func componentsContainsSubsequence(_ components: [String], _ subsequence: [String]) -> Bool {
        guard !subsequence.isEmpty, components.count >= subsequence.count else { return false }
        for index in 0...(components.count - subsequence.count) {
            if Array(components[index..<(index + subsequence.count)]) == subsequence {
                return true
            }
        }
        return false
    }

    private var sourceLikeFirstComponents: Set<String> {
        ["src", "app", "lib", "config", "cmd", "internal", "pkg", "test", "tests", "public", "resources"]
    }

    private var hostSyncedFileNames: Set<String> {
        [
            "Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
            ".dockerignore", ".conjetignore", "package.json", "pnpm-lock.yaml", "package-lock.json",
            "yarn.lock", "composer.json", "composer.lock", "Cargo.toml", "Cargo.lock",
            "go.mod", "go.sum", "pyproject.toml", "uv.lock", "poetry.lock", "requirements.txt",
            "pom.xml", "build.gradle", "gradle.lockfile", "Makefile"
        ]
    }

    private var ignoredComponents: Set<String> {
        [".git", ".hg", ".svn", ".idea", ".Trash"]
    }

    private var ignoredSuffixes: Set<String> {
        [".swp", ".tmp", ".temp", ".log", ".pid"]
    }

    private var lazySyncedComponents: Set<String> {
        ["storybook-static", "reports", "screenshots", "playwright-report"]
    }

    private var exportOnDemandComponents: Set<String> {
        ["artifacts", "release", "releases", "bundle", "bundles"]
    }
}
