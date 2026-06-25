import ConjetCore
import XCTest

final class ConjetCoreReleaseResolverTests: XCTestCase {
    func testSelectsArm64DockerRawGzAssetAndChecksum() throws {
        let json = """
        {
          "tag_name": "conjet-core-v0.1.0",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-rootfs-x86_64-docker.raw.gz",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/x86.raw.gz"
            },
            {
              "name": "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz"
            },
            {
              "name": "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz.json",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz.json"
            },
            {
              "name": "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz.sha512sum",
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
        XCTAssertEqual(artifact.name, "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz")
        XCTAssertEqual(artifact.downloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz")
        XCTAssertEqual(artifact.metadataName, "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz.json")
        XCTAssertEqual(artifact.metadataDownloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz.json")
        XCTAssertEqual(artifact.checksumName, "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz.sha512sum")
        XCTAssertEqual(artifact.checksumDownloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz.sha512sum")
    }

    func testSelectsArm64KernelImageAssetAndChecksum() throws {
        let json = """
        {
          "tag_name": "conjet-core-v0.3.0",
          "assets": [
            {
              "name": "conjet-linux-6.12.86-x86_64-Image",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/linux-x86-Image"
            },
            {
              "name": "conjet-linux-6.12.86-aarch64-Image",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/linux-arm-Image"
            },
            {
              "name": "conjet-linux-6.12.86-aarch64-Image.json",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/linux-arm-Image.json"
            },
            {
              "name": "conjet-linux-6.12.86-aarch64-Image.sha512sum",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/linux-arm-Image.sha512sum"
            }
          ]
        }
        """

        let artifact = try ConjetCoreReleaseResolver.selectKernelArtifact(
            fromLatestReleaseJSON: Data(json.utf8),
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(artifact.releaseTag, "conjet-core-v0.3.0")
        XCTAssertEqual(artifact.name, "conjet-linux-6.12.86-aarch64-Image")
        XCTAssertEqual(artifact.downloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/linux-arm-Image")
        XCTAssertEqual(artifact.metadataName, "conjet-linux-6.12.86-aarch64-Image.json")
        XCTAssertEqual(artifact.metadataDownloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/linux-arm-Image.json")
        XCTAssertEqual(artifact.checksumName, "conjet-linux-6.12.86-aarch64-Image.sha512sum")
        XCTAssertEqual(artifact.checksumDownloadURL, "https://github.com/omega13-engr/conjet/releases/download/tag/linux-arm-Image.sha512sum")
    }

    func testSelectsKernelArtifactsFromStableReleasesNewestFirst() throws {
        let json = """
        [
          {
            "tag_name": "conjet-core-v0.1.0",
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "conjet-linux-6.12.80-aarch64-Image",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.1.0/linux-arm-Image"
              }
            ]
          },
          {
            "tag_name": "conjet-core-v0.3.0",
            "draft": false,
            "prerelease": true,
            "assets": [
              {
                "name": "conjet-linux-6.12.99-aarch64-Image",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.3.0/linux-arm-Image"
              }
            ]
          },
          {
            "tag_name": "conjet-core-v0.2.0",
            "draft": false,
            "prerelease": false,
            "assets": [
              {
                "name": "conjet-linux-6.12.86-aarch64-Image",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.2.0/linux-arm-Image"
              },
              {
                "name": "conjet-linux-6.12.86-aarch64-Image.json",
                "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/conjet-core-v0.2.0/linux-arm-Image.json"
              }
            ]
          }
        ]
        """

        let artifacts = try ConjetCoreReleaseResolver.selectKernelArtifacts(
            fromLatestReleaseJSON: Data(json.utf8),
            hostArchitecture: "arm64"
        )

        XCTAssertEqual(artifacts.map(\.releaseTag), ["conjet-core-v0.2.0", "conjet-core-v0.1.0"])
        XCTAssertEqual(artifacts[0].name, "conjet-linux-6.12.86-aarch64-Image")
        XCTAssertEqual(artifacts[0].metadataName, "conjet-linux-6.12.86-aarch64-Image.json")
        XCTAssertEqual(artifacts[1].name, "conjet-linux-6.12.80-aarch64-Image")
    }

    func testRejectsMissingArchitectureAsset() throws {
        let json = """
        {
          "tag_name": "conjet-core-v0.1.0",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-rootfs-x86_64-docker.raw.gz",
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

    func testRejectsMissingKernelImageAsset() throws {
        let json = """
        {
          "tag_name": "conjet-core-v0.3.0",
          "assets": [
            {
              "name": "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz",
              "browser_download_url": "https://github.com/omega13-engr/conjet/releases/download/tag/arm.raw.gz"
            }
          ]
        }
        """

        XCTAssertThrowsError(
            try ConjetCoreReleaseResolver.selectKernelArtifact(
                fromLatestReleaseJSON: Data(json.utf8),
                hostArchitecture: "arm64"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("no kernel asset matching"))
        }
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
                "name": "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz",
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
                "name": "conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz",
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
