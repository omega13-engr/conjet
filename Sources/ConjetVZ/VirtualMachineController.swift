import ConjetCore
import Foundation

#if canImport(Virtualization)
@preconcurrency import Virtualization
#endif

public final class VirtualMachineController {
    private let queue = DispatchQueue(label: "dev.conjet.vm")
    private var state: VMRunState = .stopped

    #if canImport(Virtualization)
    private var machine: VZVirtualMachine?
    private var retainedResources: VZRuntimeResources?
    private var dockerBridge: DockerSocketBridge?
    private var publishedPortForwarder: DockerPublishedPortForwarder?
    #endif

    public init() {}

    public func status(store: VMImageStore) -> VMRuntimeStatus {
        #if canImport(Virtualization)
        if let machine {
            return store.status(state: mapState(machine.state), message: "VZ virtual machine is \(mapState(machine.state).rawValue)")
        }
        #endif
        return store.status(state: state, message: "VZ virtual machine is \(state.rawValue)")
    }

    public func networkStatus(config: ConjetConfig) -> ConjetNetworkStatus {
        #if canImport(Virtualization)
        if let publishedPortForwarder {
            return publishedPortForwarder.status()
        }
        #endif
        return ConjetNetworkStatus(
            bindPolicy: config.networkBindPolicy,
            proxyEngine: config.networkProxyEngine.rawValue,
            requestedBridgeEngine: config.networkBridgeEngine.rawValue,
            fallbackReason: "network proxy is not running",
            eventWatcherState: "stopped",
            capabilities: ConjetNetworkCapabilities(),
            messages: ["network proxy is not running"]
        )
    }

    public func repairNetwork(config: ConjetConfig) -> ConjetNetworkStatus {
        #if canImport(Virtualization)
        if let publishedPortForwarder {
            publishedPortForwarder.repair()
            return publishedPortForwarder.status()
        }
        #endif
        return networkStatus(config: config)
    }

    public func pruneCache(config: ConjetConfig) -> ConjetNetworkStatus {
        #if canImport(Virtualization)
        if let publishedPortForwarder {
            publishedPortForwarder.pruneCache()
            return publishedPortForwarder.status()
        }
        #endif
        return networkStatus(config: config)
    }

    public func start(manifest: VMAssetManifest, config: ConjetConfig, store: VMImageStore) throws -> VMRuntimeStatus {
        #if canImport(Virtualization)
        if let machine, mapState(machine.state) == .running || mapState(machine.state) == .starting {
            return manifest.runtimeStatus(state: mapState(machine.state), message: "VM is already \(mapState(machine.state).rawValue)", manifestPath: store.paths.vmManifest.path)
        }

        let configured = try VZConfigurationBuilder.build(manifest: manifest, config: config)
        do {
            try configured.configuration.validate()
        } catch {
            throw ConjetError.unavailable("VZ configuration did not validate: \(error)")
        }

        let vm = VZVirtualMachine(configuration: configured.configuration, queue: queue)
        machine = vm
        retainedResources = configured.resources
        state = .starting

        let semaphore = DispatchSemaphore(value: 0)
        let startError = AsyncErrorBox()
        let vmBox = VZMachineBox(vm)
        queue.async {
            vmBox.machine.start { result in
                if case .failure(let error) = result {
                    startError.set(error)
                }
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            state = .error
            throw ConjetError.unavailable("timed out waiting for VZ VM to start")
        }
        if let startError = startError.get() {
            state = .error
            throw ConjetError.unavailable("failed to start VZ VM: \(startError)")
        }
        try startDockerBridge(for: vm, manifest: manifest, config: config)
        state = .running
        return manifest.runtimeStatus(state: .running, message: "VM started", manifestPath: store.paths.vmManifest.path)
        #else
        throw ConjetError.unavailable("Virtualization.framework is not available in this build")
        #endif
    }

    public func stop(store: VMImageStore) throws -> VMRuntimeStatus {
        #if canImport(Virtualization)
        publishedPortForwarder?.stop()
        publishedPortForwarder = nil
        dockerBridge?.stop()
        dockerBridge = nil

        guard let machine else {
            state = .stopped
            return store.status(state: .stopped, message: "VM is not running")
        }

        if mapState(machine.state) == .stopped {
            self.machine = nil
            retainedResources = nil
            state = .stopped
            return store.status(state: .stopped, message: "VM is already stopped")
        }

        state = .stopping
        let semaphore = DispatchSemaphore(value: 0)
        let stopError = AsyncErrorBox()
        let vmBox = VZMachineBox(machine)
        queue.async {
            if vmBox.machine.canStop {
                vmBox.machine.stop { error in
                    stopError.set(error)
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            throw ConjetError.unavailable("timed out waiting for VZ VM to stop")
        }
        if let stopError = stopError.get() {
            throw ConjetError.unavailable("failed to stop VZ VM: \(stopError)")
        }
        self.machine = nil
        retainedResources = nil
        state = .stopped
        return store.status(state: .stopped, message: "VM stopped")
        #else
        return store.status(state: .stopped, message: "Virtualization.framework is not available in this build")
        #endif
    }

    #if canImport(Virtualization)
    private func mapState(_ state: VZVirtualMachine.State) -> VMRunState {
        switch state {
        case .stopped:
            return .stopped
        case .running:
            return .running
        case .starting:
            return .starting
        case .stopping:
            return .stopping
        case .error:
            return .error
        default:
            return self.state
        }
    }

    private func startDockerBridge(
        for machine: VZVirtualMachine,
        manifest: VMAssetManifest,
        config: ConjetConfig
    ) throws {
        guard let socketDevice = machine.socketDevices.compactMap({ $0 as? VZVirtioSocketDevice }).first else {
            throw ConjetError.unavailable("VM started without a virtio socket device; cannot expose Docker socket")
        }
        dockerBridge?.stop()
        let retryingConnector = RetryingGuestConnectionConnector(
            base: VZGuestConnectionConnector(socketDevice: socketDevice, queue: queue),
            timeoutSeconds: 90,
            intervalSeconds: 0.5
        )
        let capabilities = GuestBridgeCapabilityProbe.capabilities(connector: retryingConnector)
        let bridgeFallbackReason = Self.bridgeFallbackReason(requested: config.networkBridgeEngine, capabilities: capabilities)
        let connector: any GuestConnectionConnector
        if capabilities.lazyUpstream {
            connector = PooledGuestConnectionConnector(
                base: retryingConnector,
                capacity: 16,
                refillDelaySeconds: 0.05
            )
        } else {
            connector = retryingConnector
        }
        let forwarder: DockerPublishedPortForwarder?
        if capabilities.tcpProxy {
            forwarder = DockerPublishedPortForwarder(
                socketPath: manifest.dockerSocketPath,
                connector: connector,
                policy: ConjetPortPolicy(
                    bindPolicy: config.networkBindPolicy,
                    lanAllowedCIDRs: config.networkLANAllowedCIDRs,
                    lanAllowedPorts: config.networkLANAllowedPorts
                ),
                proxyEngine: config.networkProxyEngine,
                capabilities: capabilities.conjetNetworkCapabilities,
                requestedBridgeEngine: config.networkBridgeEngine,
                bridgeFallbackReason: bridgeFallbackReason,
                energyMode: config.energyMode
            )
        } else {
            forwarder = nil
        }
        let createPublicationIntentHandler: DockerSocketBridge.CreatePublicationIntentHandler?
        if let forwarder {
            createPublicationIntentHandler = { [weak forwarder] (intent: DockerCreatePublicationIntent) in
                guard let forwarder else { return }
                forwarder.observeCreatePublicationIntent(intent)
            }
        } else {
            createPublicationIntentHandler = nil
        }
        let createPublicationResolutionHandler: DockerSocketBridge.CreatePublicationResolutionHandler?
        if let forwarder {
            createPublicationResolutionHandler = { [weak forwarder] (resolution: DockerCreatePublicationResolution) in
                guard let forwarder else { return }
                forwarder.resolveCreatePublication(resolution)
            }
        } else {
            createPublicationResolutionHandler = nil
        }
        let containerStartIntentHandler: DockerSocketBridge.ContainerStartIntentHandler?
        if let forwarder {
            containerStartIntentHandler = { [weak forwarder] (request: DockerContainerStartRequest) in
                guard let forwarder else { return }
                forwarder.observeContainerStartIntent(request)
            }
        } else {
            containerStartIntentHandler = nil
        }
        let containerStartHandler: DockerSocketBridge.ContainerStartHandler?
        if let forwarder {
            containerStartHandler = { [weak forwarder] (request: DockerContainerStartRequest) in
                guard let forwarder else { return }
                forwarder.observeContainerStart(request)
            }
        } else {
            containerStartHandler = nil
        }

        if let forwarder {
            forwarder.start()
            publishedPortForwarder = forwarder
        } else {
            publishedPortForwarder = nil
        }

        let bridge = DockerSocketBridge(
            socketPath: manifest.dockerSocketPath,
            connector: connector,
            createPublicationIntentHandler: createPublicationIntentHandler,
            createPublicationResolutionHandler: createPublicationResolutionHandler,
            containerStartIntentHandler: containerStartIntentHandler,
            containerStartHandler: containerStartHandler
        )
        do {
            try bridge.start()
        } catch {
            forwarder?.stop()
            publishedPortForwarder = nil
            throw error
        }
        dockerBridge = bridge
    }
    #endif
}

extension VirtualMachineController: @unchecked Sendable {}

#if canImport(Virtualization)
private extension VirtualMachineController {
    static func bridgeFallbackReason(
        requested: ConjetNetworkBridgeEngine,
        capabilities: GuestBridgeCapabilities
    ) -> String? {
        guard requested != .auto else { return nil }
        let active = capabilities.bridgeEngine ?? "python-legacy"
        guard active != requested.rawValue else { return nil }
        if requested == .conjetNetdC {
            return "requested conjet-netd-c but active bridge is \(active); rebuild/import a Conjet Core image with /usr/local/sbin/conjet-netd or set the guest bridge engine"
        }
        return "requested \(requested.rawValue) but active bridge is \(active)"
    }
}

private struct VZRuntimeResources {
    var serialLogHandle: FileHandle
}

private struct VZConfiguredMachine {
    var configuration: VZVirtualMachineConfiguration
    var resources: VZRuntimeResources
}

private enum VZConfigurationBuilder {
    static func build(manifest: VMAssetManifest, config: ConjetConfig) throws -> VZConfiguredMachine {
        try VMImageStore().validateManifest(manifest)

        let vmConfig = VZVirtualMachineConfiguration()
        if #available(macOS 12.0, *) {
            vmConfig.platform = VZGenericPlatformConfiguration()
        }

        vmConfig.bootLoader = try bootLoader(manifest: manifest)
        let minimumCPUCount = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maximumCPUCount = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let requestedCPUs: Int
        switch config.energyMode {
        case .performance, .balanced:
            requestedCPUs = config.vmCPUs
        case .eco:
            requestedCPUs = max(1, config.vmCPUs / 2)
        }
        vmConfig.cpuCount = max(minimumCPUCount, min(requestedCPUs, maximumCPUCount))
        vmConfig.memorySize = UInt64(config.memoryMiB) * 1024 * 1024

        vmConfig.storageDevices = try storageDevices(manifest: manifest)
        vmConfig.networkDevices = [networkDevice()]
        vmConfig.serialPorts = [try serialPort(path: manifest.serialLogPath)]
        vmConfig.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vmConfig.directorySharingDevices = try directoryShares(manifest: manifest, config: config)

        let serialLogHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: manifest.serialLogPath))
        try serialLogHandle.seekToEnd()
        return VZConfiguredMachine(configuration: vmConfig, resources: VZRuntimeResources(serialLogHandle: serialLogHandle))
    }

    private static func bootLoader(manifest: VMAssetManifest) throws -> VZBootLoader {
        switch manifest.bootLoaderKind {
        case .linuxKernel:
            let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: manifest.kernelPath))
            bootLoader.commandLine = manifest.kernelCommandLine
            if let initialRamdiskPath = manifest.initialRamdiskPath {
                bootLoader.initialRamdiskURL = URL(fileURLWithPath: initialRamdiskPath)
            }
            return bootLoader
        case .efiDisk:
            guard #available(macOS 13.0, *) else {
                throw ConjetError.unavailable("EFI disk boot requires macOS 13.0 or newer")
            }
            guard let variableStorePath = manifest.efiVariableStorePath, !variableStorePath.isEmpty else {
                throw ConjetError.unavailable("EFI disk boot requires efiVariableStorePath in the VM manifest")
            }
            let variableStoreURL = URL(fileURLWithPath: variableStorePath)
            let variableStore: VZEFIVariableStore
            if FileManager.default.fileExists(atPath: variableStoreURL.path) {
                variableStore = VZEFIVariableStore(url: variableStoreURL)
            } else {
                try FileManager.default.createDirectory(
                    at: variableStoreURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                variableStore = try VZEFIVariableStore(creatingVariableStoreAt: variableStoreURL, options: [])
            }
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = variableStore
            return bootLoader
        case .linuxArm64CompressedEfiZboot:
            throw ConjetError.unavailable("compressed ARM64 EFI zboot artifacts need EFI disk boot, not VZLinuxBootLoader")
        }
    }

    private static func storageDevices(manifest: VMAssetManifest) throws -> [VZVirtioBlockDeviceConfiguration] {
        switch manifest.bootLoaderKind {
        case .efiDisk:
            let bootDisk = manifest.bootDiskPath ?? manifest.rootDiskPath
            var devices = [
                try blockDevice(path: bootDisk, identifier: "conjet-efi-boot", readOnly: false),
                try blockDevice(path: manifest.dataDiskPath, identifier: "conjet-data", readOnly: false)
            ]
            if let cloudInitSeedPath = manifest.cloudInitSeedPath {
                devices.append(try blockDevice(path: cloudInitSeedPath, identifier: "conjet-cloud-init", readOnly: true))
            }
            return devices
        case .linuxKernel, .linuxArm64CompressedEfiZboot:
            return [
                try blockDevice(path: manifest.rootDiskPath, identifier: "conjet-root", readOnly: false),
                try blockDevice(path: manifest.dataDiskPath, identifier: "conjet-data", readOnly: false)
            ]
        }
    }

    private static func blockDevice(path: String, identifier: String, readOnly: Bool) throws -> VZVirtioBlockDeviceConfiguration {
        let attachment: VZDiskImageStorageDeviceAttachment
        if #available(macOS 12.0, *) {
            let modes = diskImageModes(identifier: identifier, readOnly: readOnly)
            attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: path),
                readOnly: readOnly,
                cachingMode: modes.caching,
                synchronizationMode: modes.synchronization
            )
        } else {
            attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: readOnly)
        }
        let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        if #available(macOS 12.3, *) {
            device.blockDeviceIdentifier = identifier
        }
        return device
    }

    @available(macOS 12.0, *)
    private static func diskImageModes(
        identifier: String,
        readOnly: Bool
    ) -> (caching: VZDiskImageCachingMode, synchronization: VZDiskImageSynchronizationMode) {
        if readOnly {
            return (.automatic, .fsync)
        }
        if identifier == "conjet-data" {
            return (.cached, .none)
        }
        return (.automatic, .fsync)
    }

    private static func networkDevice() -> VZVirtioNetworkDeviceConfiguration {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        return network
    }

    private static func serialPort(path: String) throws -> VZVirtioConsoleDeviceSerialPortConfiguration {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try output.seekToEnd()
        let attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: output)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = attachment
        return serial
    }

    private static func directoryShares(manifest: VMAssetManifest, config: ConjetConfig) throws -> [VZDirectorySharingDeviceConfiguration] {
        var devices: [VZDirectorySharingDeviceConfiguration] = []

        let bootstrapDevice = VZVirtioFileSystemDeviceConfiguration(tag: "conjetboot")
        let bootstrapDirectory = VZSharedDirectory(url: URL(fileURLWithPath: manifest.bootstrapSharePath), readOnly: false)
        bootstrapDevice.share = VZSingleDirectoryShare(directory: bootstrapDirectory)
        devices.append(bootstrapDevice)

        if config.enableHostMounts {
            devices.append(contentsOf: hostDirectoryShares())
        }

        #if arch(arm64)
        if config.enableRosetta, #available(macOS 13.0, *), VZLinuxRosettaDirectoryShare.availability == .installed {
            let rosettaDevice = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            rosettaDevice.share = try? VZLinuxRosettaDirectoryShare()
            if rosettaDevice.share != nil {
                devices.append(rosettaDevice)
            }
        }
        #endif

        return devices
    }

    private static func hostDirectoryShares() -> [VZDirectorySharingDeviceConfiguration] {
        let hostShares = [
            ("conjethostusers", "/Users"),
            ("conjethostvolumes", "/Volumes")
        ]
        return hostShares.compactMap { tag, path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            let directory = VZSharedDirectory(url: URL(fileURLWithPath: path, isDirectory: true), readOnly: false)
            device.share = VZSingleDirectoryShare(directory: directory)
            return device
        }
    }
}
#endif

private final class AsyncErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error?) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        let value = error
        lock.unlock()
        return value
    }
}

#if canImport(Virtualization)
private final class VZMachineBox: @unchecked Sendable {
    let machine: VZVirtualMachine

    init(_ machine: VZVirtualMachine) {
        self.machine = machine
    }
}
#endif
