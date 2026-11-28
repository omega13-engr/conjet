import Foundation

public enum ConjetBuildVersion {
    public static func display(
        executable: String = CommandLine.arguments.first ?? ""
    ) -> String {
        var directory = URL(fileURLWithPath: executable)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app",
               let bundle = Bundle(url: directory),
               let identifier = bundle.bundleIdentifier,
               ["dev.conjet.app", "dev.conjet.app.menubar"].contains(identifier),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               !version.isEmpty {
                return "Conjet \(version)"
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory {
                break
            }
            directory = parent
        }
        return "Conjet (source build)"
    }
}
