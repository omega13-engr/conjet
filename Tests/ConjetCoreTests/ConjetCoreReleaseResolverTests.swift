import ConjetCore
import XCTest

final class ConjetCoreReleaseResolverTests: XCTestCase {
    func testSelectsArm64DockerRawGzAssetAndChecksum() throws {
        let json = """
        {
          "tag_name": "conjet-core-20260529-1",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-x86_64-docker.raw.gz",
              "browser_download_url": "https://github.com/zdxsector/conjet/releases/download/tag/x86.raw.gz"
            },
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz",
              "browser_download_url": "https://github.com/zdxsector/conjet/releases/download/tag/arm.raw.gz"
            },
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz.sha512sum",
              "browser_download_url": "https://github.com/zdxsector/conjet/releases/download/tag/arm.raw.gz.sha512sum"
            }
          ]
        }
        """

        let artifact = try ConjetCoreReleaseResolver.selectArtifact(
            fromLatestReleaseJSON: Data(json.utf8),
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(artifact.releaseTag, "conjet-core-20260529-1")
        XCTAssertEqual(artifact.name, "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz")
        XCTAssertEqual(artifact.downloadURL, "https://github.com/zdxsector/conjet/releases/download/tag/arm.raw.gz")
        XCTAssertEqual(artifact.checksumName, "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz.sha512sum")
        XCTAssertEqual(artifact.checksumDownloadURL, "https://github.com/zdxsector/conjet/releases/download/tag/arm.raw.gz.sha512sum")
    }

    func testRejectsMissingArchitectureAsset() throws {
        let json = """
        {
          "tag_name": "conjet-core-20260529-1",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-x86_64-docker.raw.gz",
              "browser_download_url": "https://github.com/zdxsector/conjet/releases/download/tag/x86.raw.gz"
            }
          ]
        }
        """

        XCTAssertThrowsError(
            try ConjetCoreReleaseResolver.selectArtifact(
                fromLatestReleaseJSON: Data(json.utf8),
                hostArchitecture: "arm64"
            )
        )
    }

    func testMapsHostArchitecturesToArtifactArchitectures() throws {
        XCTAssertEqual(try ConjetCoreReleaseResolver.artifactArchitecture(hostArchitecture: "arm64"), "aarch64")
        XCTAssertEqual(try ConjetCoreReleaseResolver.artifactArchitecture(hostArchitecture: "arm64e"), "aarch64")
        XCTAssertEqual(try ConjetCoreReleaseResolver.artifactArchitecture(hostArchitecture: "x86_64"), "x86_64")
        XCTAssertEqual(try ConjetCoreReleaseResolver.artifactArchitecture(hostArchitecture: "amd64"), "x86_64")
    }
}
