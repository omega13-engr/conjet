import Darwin
import Foundation

public struct ConjetIgnore: Equatable, Sendable {
    public var rules: [IgnoreRule]

    public init(rules: [IgnoreRule] = IgnoreRule.defaultRules) {
        self.rules = rules
    }

    public static func parse(_ text: String) -> ConjetIgnore {
        let rules = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { IgnoreRule.parse(String($0)) }
        return ConjetIgnore(rules: rules)
    }

    public func isIgnored(_ rawPath: String) -> Bool {
        let path = normalizePath(rawPath)
        var ignored = false
        for rule in rules where rule.matches(path) {
            ignored = !rule.negated
        }
        return ignored
    }
}

public struct IgnoreRule: Equatable, Sendable {
    public var pattern: String
    public var negated: Bool

    public init(pattern: String, negated: Bool = false) {
        self.pattern = pattern
        self.negated = negated
    }

    public static let defaultRules: [IgnoreRule] = [
        IgnoreRule(pattern: ".DS_Store"),
        IgnoreRule(pattern: ".git/"),
        IgnoreRule(pattern: "*.swp"),
        IgnoreRule(pattern: "*.tmp"),
        IgnoreRule(pattern: "*.log"),
        IgnoreRule(pattern: ".idea/"),
        IgnoreRule(pattern: ".vscode/.browse.VC.db*")
    ]

    public static func parse(_ line: String) -> IgnoreRule? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("!") {
            return IgnoreRule(pattern: String(trimmed.dropFirst()), negated: true)
        }
        return IgnoreRule(pattern: trimmed)
    }

    public func matches(_ rawPath: String) -> Bool {
        let path = normalizePath(rawPath)
        let normalizedPattern = normalizePath(pattern)

        if normalizedPattern.hasSuffix("/") {
            let directory = String(normalizedPattern.dropLast())
            return path == directory || path.hasPrefix(directory + "/")
        }

        if normalizedPattern.contains("/") {
            return fnmatch(normalizedPattern, path, FNM_PATHNAME) == 0
                || path.hasPrefix(normalizedPattern + "/")
        }

        if fnmatch(normalizedPattern, basename(path), 0) == 0 {
            return true
        }

        return path.split(separator: "/").contains { component in
            fnmatch(normalizedPattern, String(component), 0) == 0
        }
    }
}

func normalizePath(_ path: String) -> String {
    var normalized = path.replacingOccurrences(of: "\\", with: "/")
    while normalized.hasPrefix("./") {
        normalized.removeFirst(2)
    }
    while normalized.hasPrefix("/") {
        normalized.removeFirst()
    }
    while normalized.contains("//") {
        normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    return normalized
}

private func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
