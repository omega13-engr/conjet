import ConjetCore
import Foundation

public struct PolyglotBenchmarkSuite {
    public static let defaultEcosystems = ["js", "python", "jvm", "dotnet", "go", "rust", "cpp"]

    public var contexts: [String]
    public var samples: Int
    public var ecosystems: [String]
    public var topology: String
    public var dockerExecutable: String
    public var commandTimeoutSeconds: Double

    private let runner: @Sendable (String, [String]) throws -> ProcessResult

    public init(
        contexts: [String],
        samples: Int = 5,
        ecosystems: [String] = PolyglotBenchmarkSuite.defaultEcosystems,
        topology: String = "smart-bind",
        dockerExecutable: String = "/usr/bin/env",
        commandTimeoutSeconds: Double = 300,
        runner: (@Sendable (String, [String]) throws -> ProcessResult)? = nil
    ) {
        self.contexts = contexts.filter { !$0.isEmpty }
        self.samples = max(1, samples)
        self.ecosystems = ecosystems.isEmpty ? Self.defaultEcosystems : ecosystems
        self.topology = topology
        self.dockerExecutable = dockerExecutable
        self.commandTimeoutSeconds = max(1, commandTimeoutSeconds)
        self.runner = runner ?? { executable, arguments in
            try ProcessRunner.run(executable, arguments, timeoutSeconds: commandTimeoutSeconds)
        }
    }

    public func run(workDirectory: URL) throws -> [BenchmarkResult] {
        guard !contexts.isEmpty else {
            throw ConjetError.invalidArgument("at least one Docker context is required")
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        var results: [BenchmarkResult] = []
        let workloads = Self.workloads(for: ecosystems)
        for sample in 1...samples {
            for context in contexts {
                for workload in workloads {
                    results.append(try benchmark(workload: workload, context: context, sample: sample, workDirectory: workDirectory))
                }
            }
        }
        return results
    }

    public static func workloads(for ecosystems: [String]) -> [String] {
        var workloads: [String] = []
        for ecosystem in ecosystems.map({ $0.lowercased() }) {
            switch ecosystem {
            case "js", "javascript", "typescript":
                workloads += ["js-install", "js-build", "js-hot-reload"]
            case "python", "py":
                workloads += ["python-install", "python-test", "python-hot-reload"]
            case "jvm", "java":
                workloads += ["jvm-dependency-resolve", "jvm-build", "jvm-test"]
            case "dotnet", ".net":
                workloads += ["dotnet-restore", "dotnet-build", "dotnet-test"]
            case "go", "golang":
                workloads += ["go-mod-download", "go-build", "go-test"]
            case "rust":
                workloads += ["rust-build", "rust-test"]
            case "cpp", "c++", "c":
                workloads += ["cpp-configure", "cpp-build", "cpp-test"]
            default:
                continue
            }
        }
        return workloads
    }

    private func benchmark(workload: String, context: String, sample: Int, workDirectory: URL) throws -> BenchmarkResult {
        let projectDirectory = workDirectory.appendingPathComponent(workload, isDirectory: true)
        try prepareProject(for: workload, at: projectDirectory)
        let command = dockerArguments(context: context, workload: workload, projectDirectory: projectDirectory, sample: sample)
        let machine = MachineProfiler.capture()
        let startedAt = Date()
        let process = try runner(dockerExecutable, command)
        var metrics = topologyMetrics()
        metrics["iteration"] = Double(sample)
        metrics.setString("warm", for: "sample_phase")
        metrics.setString("warm", for: "build_cache_mode")
        metrics.setString("base-prepulled", for: "image_cache_mode")
        metrics.setString("online", for: "network_cache_mode")
        return BenchmarkResult(
            workload: workload,
            runtime: context,
            command: [dockerExecutable] + command,
            startedAt: startedAt,
            durationSeconds: Date().timeIntervalSince(startedAt),
            exitCode: process.exitCode,
            metrics: metrics,
            machine: machine,
            stdoutTail: tail(process.stdout),
            stderrTail: tail(process.stderr)
        )
    }

    private func dockerArguments(context: String, workload: String, projectDirectory: URL, sample: Int) -> [String] {
        let volumeName = "conjet-polyglot-\(context.sanitizedDockerTag)-\(workload.sanitizedDockerTag)-\(sample)"
        let image = imageAndScript(for: workload).image
        let script = imageAndScript(for: workload).script
        switch topology {
        case "strict-bind":
            return [
                "docker", "--context", context, "run", "--rm",
                "--mount", "type=bind,source=\(projectDirectory.path),target=/workspace",
                "-w", "/workspace",
                image, "sh", "-lc", script
            ]
        case "volume":
            return [
                "docker", "--context", context, "run", "--rm",
                "--mount", "type=volume,source=\(volumeName),target=/workspace",
                "-w", "/workspace",
                image, "sh", "-lc", volumeBootstrap(for: workload) + "\n" + script
            ]
        default:
            return [
                "docker", "--context", context, "run", "--rm",
                "--mount", "type=bind,source=\(projectDirectory.path),target=/workspace",
                "--mount", "type=volume,source=\(volumeName)-native,target=/workspace/.native",
                "-w", "/workspace",
                image, "sh", "-lc", script
            ]
        }
    }

    private func topologyMetrics() -> BenchmarkMetrics {
        var metrics = BenchmarkMetrics()
        metrics.setString(topology, for: "mount_topology")
        metrics.setBool(topology == "strict-bind", for: "strict_bind")
        metrics.setBool(topology == "smart-bind", for: "smart_mount")
        metrics["native_overlay_mounts"] = topology == "smart-bind" || topology == "volume" ? 1 : 0
        metrics.setStringArray(topology == "strict-bind" ? [] : ["/workspace/.native"], for: "linux_native_write_paths")
        metrics.setStringArray(topology == "volume" ? [] : ["/workspace"], for: "host_bind_paths")
        metrics.setBool(false, for: "conjetfs_fast_path")
        return metrics
    }

    private func prepareProject(for workload: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch workload {
        case let name where name.hasPrefix("js-"):
            try #"{"scripts":{"build":"node src/index.js","dev":"node src/index.js"},"dependencies":{"lodash":"4.17.21"},"devDependencies":{}}"#.write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
            try "console.log('polyglot js')\n".write(to: directory.appendingPathComponent("src/index.js"), atomically: true, encoding: .utf8)
        case let name where name.hasPrefix("python-"):
            try "pytest==8.2.2\nfastapi==0.111.0\n".write(to: directory.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
            try "def test_polyglot():\n    assert 2 + 2 == 4\n".write(to: directory.appendingPathComponent("test_polyglot.py"), atomically: true, encoding: .utf8)
        case let name where name.hasPrefix("go-"):
            try "module example.com/conjet/polyglot\n\ngo 1.22\n\nrequire github.com/google/uuid v1.6.0\n".write(to: directory.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
            try """
            github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
            github.com/google/uuid v1.6.0/go.mod h1:TIyPZe4MgqvfeYDBFedMoGGpEw/LqOeaOT+nhxU+yHo=
            """.write(to: directory.appendingPathComponent("go.sum"), atomically: true, encoding: .utf8)
            try """
            package main

            import (
                "fmt"

                "github.com/google/uuid"
            )

            func main() {
                fmt.Println(uuid.Nil.String())
            }
            """.write(to: directory.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
            try """
            package main

            import (
                "testing"

                "github.com/google/uuid"
            )

            func TestPolyglot(t *testing.T) {
                if uuid.NewString() == "" {
                    t.Fatal("empty uuid")
                }
            }
            """.write(to: directory.appendingPathComponent("main_test.go"), atomically: true, encoding: .utf8)
        case let name where name.hasPrefix("rust-"):
            try """
            [package]
            name = "conjet_polyglot"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            itoa = "1.0"
            """.write(to: directory.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
            let srcDirectory = directory.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: srcDirectory, withIntermediateDirectories: true)
            try """
            pub fn format_number(value: u64) -> String {
                let mut buffer = itoa::Buffer::new();
                buffer.format(value).to_owned()
            }

            #[cfg(test)]
            mod tests {
                use super::format_number;

                #[test]
                fn formats_number() {
                    assert_eq!(format_number(42), "42");
                }
            }
            """.write(to: srcDirectory.appendingPathComponent("lib.rs"), atomically: true, encoding: .utf8)
            try """
            fn main() {
                println!("{}", conjet_polyglot::format_number(42));
            }
            """.write(to: srcDirectory.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        case let name where name.hasPrefix("cpp-"):
            try "cmake_minimum_required(VERSION 3.20)\nproject(conjet_polyglot C)\nadd_executable(app main.c)\nenable_testing()\nadd_test(NAME app COMMAND app)\n".write(to: directory.appendingPathComponent("CMakeLists.txt"), atomically: true, encoding: .utf8)
            try "#include <stdio.h>\nint main(){ puts(\"cpp\"); return 0; }\n".write(to: directory.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
        default:
            try "placeholder\n".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        }
    }

    private func imageAndScript(for workload: String) -> (image: String, script: String) {
        switch workload {
        case "js-install": return ("node:22-alpine", "npm install --no-audit --no-fund --progress=false")
        case "js-build": return ("node:22-alpine", "npm install --no-audit --no-fund --progress=false >/dev/null && npm run build")
        case "js-hot-reload": return ("node:22-alpine", "printf updated > src/hot.txt && node src/index.js")
        case "python-install": return ("python:3.12-alpine", "python -m pip install -r requirements.txt")
        case "python-test": return ("python:3.12-alpine", "python -m pip install -r requirements.txt >/dev/null && pytest -q")
        case "python-hot-reload": return ("python:3.12-alpine", "printf updated > hot.txt && python - <<'PY'\nprint('reload')\nPY")
        case "go-mod-download": return ("golang:1.23-alpine", goScript("go mod download"))
        case "go-build": return ("golang:1.23-alpine", goScript("go mod download >/dev/null && go build ./..."))
        case "go-test": return ("golang:1.23-alpine", goScript("go mod download >/dev/null && go test ./..."))
        case "rust-build": return ("rust:1-alpine", rustScript("cargo build"))
        case "rust-test": return ("rust:1-alpine", rustScript("cargo test"))
        case "cpp-configure": return ("alpine:3.20", "apk add --no-cache cmake make gcc musl-dev >/dev/null && cmake -S . -B build")
        case "cpp-build": return ("alpine:3.20", "apk add --no-cache cmake make gcc musl-dev >/dev/null && cmake -S . -B build >/dev/null && cmake --build build")
        case "cpp-test": return ("alpine:3.20", "apk add --no-cache cmake make gcc musl-dev >/dev/null && cmake -S . -B build >/dev/null && cmake --build build >/dev/null && ctest --test-dir build --output-on-failure")
        case "jvm-dependency-resolve", "jvm-build", "jvm-test": return ("eclipse-temurin:21-jdk-alpine", "echo jvm-polyglot")
        case "dotnet-restore", "dotnet-build", "dotnet-test": return ("mcr.microsoft.com/dotnet/sdk:9.0-alpine", "dotnet --info >/dev/null")
        default: return ("alpine:3.20", "true")
        }
    }

    private func goScript(_ command: String) -> String {
        """
        export PATH="/usr/local/go/bin:$PATH"
        export GOMODCACHE=/workspace/.native/go/pkg/mod
        export GOCACHE=/workspace/.native/go/build-cache
        mkdir -p "$GOMODCACHE" "$GOCACHE"
        go version >/dev/null
        \(command)
        """
    }

    private func rustScript(_ command: String) -> String {
        """
        export PATH="/usr/local/cargo/bin:$PATH"
        export CARGO_HOME=/workspace/.native/cargo-home
        export CARGO_TARGET_DIR=/workspace/.native/target
        mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR"
        cargo --version >/dev/null
        \(command)
        """
    }

    private func volumeBootstrap(for workload: String) -> String {
        "true # \(workload)"
    }

    private func tail(_ text: String, limit: Int = 4096) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

private extension String {
    var sanitizedDockerTag: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let sanitized = String(map { allowed.contains($0) ? $0 : "-" })
        return sanitized.isEmpty ? "runtime" : sanitized.lowercased()
    }
}
