import Dispatch
import Foundation

#if canImport(CoreServices)
import CoreServices
#endif

public struct ConjetFSWatchEvent: Codable, Equatable, Sendable {
    public var root: String
    public var changedPaths: [String]
    public var occurredAt: String

    public init(
        root: String,
        changedPaths: [String],
        occurredAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.root = root
        self.changedPaths = changedPaths
        self.occurredAt = occurredAt
    }
}

public struct ConjetFSWatchBatcher: Sendable {
    public var root: URL
    public var ignoredPrefixes: Set<String>

    private var pendingPaths: Set<String> = []

    public init(root: URL, ignoredPrefixes: Set<String> = [".conjet"]) {
        self.root = root.standardizedFileURL
        self.ignoredPrefixes = ignoredPrefixes
    }

    public mutating func insert(rawPaths: [String]) {
        for rawPath in rawPaths {
            guard let path = normalize(rawPath) else {
                continue
            }
            pendingPaths.insert(path)
        }
    }

    public mutating func flush() -> ConjetFSWatchEvent? {
        guard !pendingPaths.isEmpty else {
            return nil
        }
        let event = ConjetFSWatchEvent(
            root: root.path,
            changedPaths: pendingPaths.sorted()
        )
        pendingPaths.removeAll(keepingCapacity: true)
        return event
    }

    private func normalize(_ rawPath: String) -> String? {
        let absolute = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let rootPath = root.path
        let relative: String
        if absolute == rootPath {
            relative = "."
        } else if absolute.hasPrefix(rootPath + "/") {
            relative = String(absolute.dropFirst(rootPath.count + 1))
        } else {
            return nil
        }

        guard !relative.isEmpty else {
            return "."
        }
        for prefix in ignoredPrefixes {
            if relative == prefix || relative.hasPrefix(prefix + "/") {
                return nil
            }
        }
        return relative
    }
}

public final class ConjetFSHostEventStream: @unchecked Sendable {
    public let root: URL
    public let debounceSeconds: Double

    private let queue = DispatchQueue(label: "conjet.conjetfs.fsevents")
    private var batcher: ConjetFSWatchBatcher
    private var flushScheduled = false
    private var onEvent: ((ConjetFSWatchEvent) -> Void)?

    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?
    #endif

    public init(
        root: URL,
        debounceSeconds: Double = 0.005,
        ignoredPrefixes: Set<String> = [".conjet"]
    ) {
        self.root = root.standardizedFileURL
        self.debounceSeconds = max(0, debounceSeconds)
        self.batcher = ConjetFSWatchBatcher(root: root, ignoredPrefixes: ignoredPrefixes)
    }

    deinit {
        stop()
    }

    public func start(onEvent: @escaping (ConjetFSWatchEvent) -> Void) throws {
        self.onEvent = onEvent
        #if canImport(CoreServices)
        guard stream == nil else {
            return
        }
        let box = ConjetFSEventCallbackBox { [weak self] paths in
            self?.enqueue(rawPaths: paths)
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                if let info {
                    Unmanaged<ConjetFSEventCallbackBox>.fromOpaque(info).release()
                }
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            conjetFSEventStreamCallback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceSeconds,
            flags
        ) else {
            throw ConjetError.unavailable("failed to create ConjetFS FSEvents stream for \(root.path)")
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw ConjetError.unavailable("failed to start ConjetFS FSEvents stream for \(root.path)")
        }
        #else
        throw ConjetError.unavailable("ConjetFS event watch requires macOS FSEvents; use --poll")
        #endif
    }

    public func run(onEvent: @escaping (ConjetFSWatchEvent) -> Void) throws {
        try start(onEvent: onEvent)
        RunLoop.current.run()
    }

    public func stop() {
        #if canImport(CoreServices)
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        #endif
    }

    private func enqueue(rawPaths: [String]) {
        queue.async {
            self.batcher.insert(rawPaths: rawPaths)
            guard !self.flushScheduled else {
                return
            }
            self.flushScheduled = true
            let flush: @Sendable () -> Void = {
                self.flushScheduled = false
                guard let event = self.batcher.flush() else {
                    return
                }
                self.onEvent?(event)
            }
            if self.debounceSeconds == 0 {
                self.queue.async(execute: flush)
            } else {
                self.queue.asyncAfter(deadline: .now() + self.debounceSeconds, execute: flush)
            }
        }
    }
}

#if canImport(CoreServices)
private final class ConjetFSEventCallbackBox {
    let callback: ([String]) -> Void

    init(callback: @escaping ([String]) -> Void) {
        self.callback = callback
    }
}

private let conjetFSEventStreamCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else {
        return
    }
    let box = Unmanaged<ConjetFSEventCallbackBox>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self)
        .compactMap { $0 as? String }
    box.callback(paths)
}
#endif
