import ConjetCore
import XCTest

final class ConjetCoreReleaseResolverTests: XCTestCase {
    func testSelectsArm64DockerRawGzAssetAndChecksum() throws {
        let json = """
        {
          "tag_name": "conjet-core-v0.1.0",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-x86_64-docker.raw.gz",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/x86.raw.gz"
            },
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz"
            },
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz.sha512sum",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz.sha512sum"
            }
          ]
        }
        """

        let artifact = try ConjetCoreReleaseResolver.selectArtifact(
            fromLatestReleaseJSON: Data(json.utf8),
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(artifact.releaseTag, "conjet-core-v0.1.0")
        XCTAssertEqual(artifact.name, "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz")
        XCTAssertEqual(artifact.downloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz")
        XCTAssertEqual(artifact.checksumName, "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz.sha512sum")
        XCTAssertEqual(artifact.checksumDownloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz.sha512sum")
    }

    func testRejectsMissingArchitectureAsset() throws {
        let json = """
        {
          "tag_name": "conjet-core-v0.1.0",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-minimal-cloudimg-x86_64-docker.raw.gz",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/x86.raw.gz"
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

    func testSelectsNewestConjetCoreSemverReleaseFromReleaseList() throws {
        let json = """
        [
          {
            "tag_name": "conjet-v9.9.9",
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "conjet-9.9.9-macos-arm64.tar.gz",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-v9.9.9/conjet.tar.gz"
              }
            ]
          },
          {
            "tag_name": "conjet-core-v0.1.0",
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.1.0/arm.raw.gz"
              }
            ]
          },
          {
            "tag_name": "conjet-core-v0.2.0",
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.2.0/arm.raw.gz"
              }
            ]
          }
        ]
        """

        let artifact = try ConjetCoreReleaseResolver.selectArtifact(
            fromLatestReleaseJSON: Data(json.utf8),
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(artifact.releaseTag, "conjet-core-v0.2.0")
        XCTAssertEqual(artifact.downloadURL, "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.2.0/arm.raw.gz")
    }

    func testRejectsReleaseListWithoutStableCoreSemverRelease() throws {
        let json = """
        [
          {
            "tag_name": "conjet-v0.1.0",
            "draft": false,
            "prerelease": false,
            "assets": []
          },
          {
            "tag_name": "conjet-core-nightly",
            "draft": false,
            "prerelease": false,
            "assets": []
          }
        ]
        """

        XCTAssertThrowsError(
            try ConjetCoreReleaseResolver.selectArtifact(
                fromLatestReleaseJSON: Data(json.utf8),
                hostArchitecture: "arm64"
            )
        )
    }
}
