import Foundation

public struct ConjetCoreReleaseSource: Codable, Equatable, Sendable {
    public static let defaultRepository = "omega13-engr/conjet"
    public static let releaseTagPrefix = "conjet-core-v"

    public var repository: String
    public var apiBaseURL: String

    public init(
        repository: String = ConjetCoreReleaseSource.defaultRepository,
        apiBaseURL: String = "https://api.github.com"
    ) {
        self.repository = repository
        self.apiBaseURL = apiBaseURL
    }

    public var releasesURL: String {
        "\(apiBaseURL)/repos/\(repository)/releases?per_page=100"
    }

    public var latestReleaseURL: String {
        releasesURL
    }
}

public struct ConjetCoreReleaseArtifact: Codable, Equatable, Sendable {
    public var releaseTag: String
    public var name: String
    public var downloadURL: String
    public var checksumName: String?
    public var checksumDownloadURL: String?

    public init(
        releaseTag: String,
        name: String,
        downloadURL: String,
        checksumName: String?,
        checksumDownloadURL: String?
    ) {
        self.releaseTag = releaseTag
        self.name = name
        self.downloadURL = downloadURL
        self.checksumName = checksumName
        self.checksumDownloadURL = checksumDownloadURL
    }
}

public enum ConjetCoreReleaseResolver {
    public static func artifactArchitecture(hostArchitecture: String) throws -> String {
        switch hostArchitecture.lowercased() {
        case "arm64", "arm64e", "aarch64":
            return "aarch64"
        case "x86_64", "amd64":
            return "x86_64"
        default:
            throw ConjetError.unavailable("no Conjet-core image architecture mapping for host architecture '\(hostArchitecture)'")
        }
    }

    public static func selectArtifact(
        fromLatestReleaseJSON data: Data,
        hostArchitecture: String,
        runtime: String = "docker"
    ) throws -> ConjetCoreReleaseArtifact {
        let release = try selectRelease(from: data)
        let imageArchitecture = try artifactArchitecture(hostArchitecture: hostArchitecture)
        let suffix = "-\(imageArchitecture)-\(runtime).raw.gz"
        let candidates = release.assets
            .filter { $0.name.hasPrefix("conjet-") && $0.name.hasSuffix(suffix) }
            .sorted { $0.name > $1.name }

        guard let image = candidates.first else {
            let names = release.assets.map(\.name).sorted().joined(separator: ", ")
            throw ConjetError.unavailable(
                "latest Conjet-core release '\(release.tagName)' has no asset matching '*\(suffix)'. Assets: \(names)"
            )
        }

        let checksumName = "\(image.name).sha512sum"
        let checksum = release.assets.first { $0.name == checksumName }
        return ConjetCoreReleaseArtifact(
            releaseTag: release.tagName,
            name: image.name,
            downloadURL: image.browserDownloadURL,
            checksumName: checksum?.name,
            checksumDownloadURL: checksum?.browserDownloadURL
        )
    }

    private static func selectRelease(from data: Data) throws -> GitHubRelease {
        let decoder = ConjetJSON.decoder()
        if let releases = try? decoder.decode([GitHubRelease].self, from: data) {
            let candidates = releases
                .filter { !($0.draft ?? false) && !($0.prerelease ?? false) }
                .compactMap { release -> (GitHubRelease, SemanticVersion)? in
                    guard let version = SemanticVersion(tag: release.tagName, prefix: ConjetCoreReleaseSource.releaseTagPrefix) else {
                        return nil
                    }
                    return (release, version)
                }
                .sorted { lhs, rhs in lhs.1 > rhs.1 }

            guard let selected = candidates.first?.0 else {
                throw ConjetError.unavailable(
                    "no stable Conjet Core image release found with tag prefix '\(ConjetCoreReleaseSource.releaseTagPrefix)'"
                )
            }
            return selected
        }

        return try decoder.decode(GitHubRelease.self, from: data)
    }
}

private struct GitHubRelease: Decodable {
    var tagName: String
    var draft: Bool?
    var prerelease: Bool?
    var assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    var name: String
    var browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct SemanticVersion: Comparable {
    var major: Int
    var minor: Int
    var patch: Int

    init?(tag: String, prefix: String) {
        guard tag.hasPrefix(prefix) else { return nil }
        let version = String(tag.dropFirst(prefix.count))
        let parts = version.split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0,
              minor >= 0,
              patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
