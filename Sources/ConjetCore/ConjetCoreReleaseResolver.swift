import Foundation

public struct ConjetCoreReleaseSource: Codable, Equatable, Sendable {
    public static let defaultRepository = "zdxsector/conjet"

    public var repository: String
    public var apiBaseURL: String

    public init(
        repository: String = ConjetCoreReleaseSource.defaultRepository,
        apiBaseURL: String = "https://api.github.com"
    ) {
        self.repository = repository
        self.apiBaseURL = apiBaseURL
    }

    public var latestReleaseURL: String {
        "\(apiBaseURL)/repos/\(repository)/releases/latest"
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
        let release = try ConjetJSON.decoder().decode(GitHubLatestRelease.self, from: data)
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
}

private struct GitHubLatestRelease: Decodable {
    var tagName: String
    var assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
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
