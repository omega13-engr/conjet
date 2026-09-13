import Foundation

public struct ComposeProjectSelection: Equatable, Sendable {
    public let directory: URL
    public let configurationFile: URL

    public static func resolve(_ path: String) throws -> ComposeProjectSelection {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SelectionError("Choose a directory containing a Compose file.")
        }
        let directory = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SelectionError("The selected project directory does not exist.")
        }
        for filename in ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"] {
            let file = directory.appendingPathComponent(filename)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                guard FileManager.default.isReadableFile(atPath: file.path) else {
                    throw SelectionError("Cannot read \(filename). Check its permissions.")
                }
                return ComposeProjectSelection(directory: directory, configurationFile: file)
            }
        }
        throw SelectionError("No compose.yaml, compose.yml, docker-compose.yml or docker-compose.yaml in this directory.")
    }

    public struct SelectionError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}
