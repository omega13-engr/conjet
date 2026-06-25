import ConjetCore
import Foundation
import XCTest

final class ConjetContainerRuntimeTests: XCTestCase {
    func testDirectOCILoaderBuildsKernelArgumentsFromSupportedBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-oci-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        let rootfs = bundle.appendingPathComponent("rootfs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)
        try writeConfig(
            to: bundle,
            process: [
                "args": ["/bin/echo", "hello world"],
                "env": ["PATH=/bin"],
                "cwd": "/work"
            ],
            root: ["path": "rootfs", "readonly": true],
            mounts: [
                ["destination": "/proc", "type": "proc"],
                ["destination": "/sys", "type": "sysfs"],
                ["destination": "/tmp", "type": "tmpfs"]
            ]
        )

        let spec = try ConjetDirectOCIBundleLoader.load(bundleURL: bundle)

        XCTAssertEqual(spec.rootfsPath, rootfs.path)
        XCTAssertEqual(spec.args, ["/bin/echo", "hello world"])
        XCTAssertEqual(spec.environment, ["PATH=/bin"])
        XCTAssertEqual(spec.workingDirectory, "/work")
        XCTAssertEqual(spec.kernelArguments, [
            "conjet.argc=2",
            "conjet.arg0=/bin/echo",
            "conjet.arg1=hello%20world",
            "conjet.cwd=/work"
        ])
        XCTAssertTrue(spec.kernelCommandLine(appendingTo: "console=hvc0").contains("conjet.arg1=hello%20world"))
    }

    func testDirectOCILoaderRejectsUnsupportedHooksAndWritableBindMounts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-oci-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        let rootfs = bundle.appendingPathComponent("rootfs", isDirectory: true)
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        try writeConfig(
            to: bundle,
            process: ["args": ["/bin/true"], "cwd": "/"],
            root: ["path": "rootfs"],
            hooks: ["prestart": [["path": "/bin/hook"]]]
        )
        XCTAssertThrowsError(try ConjetDirectOCIBundleLoader.load(bundleURL: bundle)) { error in
            XCTAssertTrue(String(describing: error).contains("does not support OCI hooks"))
        }

        try writeConfig(
            to: bundle,
            process: ["args": ["/bin/true"], "cwd": "/"],
            root: ["path": "rootfs"],
            mounts: [["destination": "/mnt", "type": "bind", "source": "/host", "options": ["rw"]]]
        )
        XCTAssertThrowsError(try ConjetDirectOCIBundleLoader.load(bundleURL: bundle)) { error in
            XCTAssertTrue(String(describing: error).contains("bind mounts must be read-only"))
        }
    }

    func testDirectOCILoaderRejectsEscapingRootfsAndRelativeProcessPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjet-oci-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        try writeConfig(
            to: bundle,
            process: ["args": ["bin/true"], "cwd": "/"],
            root: ["path": "../rootfs"]
        )
        XCTAssertThrowsError(try ConjetDirectOCIBundleLoader.load(bundleURL: bundle)) { error in
            XCTAssertTrue(String(describing: error).contains("process.args[0] must be an absolute guest path"))
        }

        try writeConfig(
            to: bundle,
            process: ["args": ["/bin/true"], "cwd": "/"],
            root: ["path": "../rootfs"]
        )
        XCTAssertThrowsError(try ConjetDirectOCIBundleLoader.load(bundleURL: bundle)) { error in
            XCTAssertTrue(String(describing: error).contains("root.path must stay inside the bundle"))
        }
    }

    private func writeConfig(
        to bundle: URL,
        process: [String: Any],
        root: [String: Any],
        mounts: [[String: Any]]? = nil,
        hooks: [String: Any]? = nil
    ) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "ociVersion": "1.1.0",
            "process": process,
            "root": root
        ]
        if let mounts {
            object["mounts"] = mounts
        }
        if let hooks {
            object["hooks"] = hooks
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: bundle.appendingPathComponent("config.json"))
    }
}
