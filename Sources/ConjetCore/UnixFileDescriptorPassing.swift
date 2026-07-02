import Darwin
import Foundation

public enum UnixFileDescriptorPassing {
    public static func send(
        fileDescriptor: Int32?,
        payload: Data,
        to socket: Int32
    ) throws {
        var payloadBytes = [UInt8](payload)
        if payloadBytes.isEmpty {
            payloadBytes = [0]
        }

        try payloadBytes.withUnsafeMutableBytes { payloadBuffer in
            var iov = iovec(
                iov_base: payloadBuffer.baseAddress,
                iov_len: payloadBuffer.count
            )

            if let fileDescriptor {
                var control = [UInt8](repeating: 0, count: controlSpaceLength)
                try control.withUnsafeMutableBytes { controlBuffer in
                    let header = controlBuffer.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                    header.pointee.cmsg_len = socklen_t(controlMessageLength)
                    header.pointee.cmsg_level = SOL_SOCKET
                    header.pointee.cmsg_type = SCM_RIGHTS
                    controlBuffer.baseAddress!
                        .advanced(by: alignedCMSHeaderLength)
                        .storeBytes(of: fileDescriptor, as: Int32.self)

                    try withUnsafeMutablePointer(to: &iov) { iovPointer in
                        var message = msghdr(
                            msg_name: nil,
                            msg_namelen: 0,
                            msg_iov: iovPointer,
                            msg_iovlen: 1,
                            msg_control: controlBuffer.baseAddress,
                            msg_controllen: socklen_t(controlBuffer.count),
                            msg_flags: 0
                        )
                        let sent = Darwin.sendmsg(socket, &message, 0)
                        guard sent >= 0 else {
                            throw ConjetError.socket("sendmsg() failed: \(String(cString: strerror(errno)))")
                        }
                    }
                }
            } else {
                try withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: iovPointer,
                        msg_iovlen: 1,
                        msg_control: nil,
                        msg_controllen: 0,
                        msg_flags: 0
                    )
                    let sent = Darwin.sendmsg(socket, &message, 0)
                    guard sent >= 0 else {
                        throw ConjetError.socket("sendmsg() failed: \(String(cString: strerror(errno)))")
                    }
                }
            }
        }
    }

    public static func receive(
        from socket: Int32,
        maxPayloadBytes: Int = 4096
    ) throws -> (fileDescriptor: Int32?, payload: Data) {
        var payloadBytes = [UInt8](repeating: 0, count: max(1, maxPayloadBytes))
        var control = [UInt8](repeating: 0, count: controlSpaceLength)

        return try payloadBytes.withUnsafeMutableBytes { payloadBuffer in
            try control.withUnsafeMutableBytes { controlBuffer in
                var iov = iovec(
                    iov_base: payloadBuffer.baseAddress,
                    iov_len: payloadBuffer.count
                )
                return try withUnsafeMutablePointer(to: &iov) { iovPointer in
                    var message = msghdr(
                        msg_name: nil,
                        msg_namelen: 0,
                        msg_iov: iovPointer,
                        msg_iovlen: 1,
                        msg_control: controlBuffer.baseAddress,
                        msg_controllen: socklen_t(controlBuffer.count),
                        msg_flags: 0
                    )

                    let received = Darwin.recvmsg(socket, &message, 0)
                    guard received >= 0 else {
                        throw ConjetError.socket("recvmsg() failed: \(String(cString: strerror(errno)))")
                    }

                    let payload = Data(
                        bytes: payloadBuffer.baseAddress!,
                        count: received
                    )
                    let descriptor = receivedFileDescriptor(
                        control: controlBuffer,
                        controlLength: Int(message.msg_controllen)
                    )
                    return (descriptor, payload)
                }
            }
        }
    }

    private static func receivedFileDescriptor(
        control: UnsafeMutableRawBufferPointer,
        controlLength: Int
    ) -> Int32? {
        guard controlLength >= controlMessageLength,
              let baseAddress = control.baseAddress else {
            return nil
        }
        let header = baseAddress.assumingMemoryBound(to: cmsghdr.self).pointee
        guard header.cmsg_level == SOL_SOCKET,
              header.cmsg_type == SCM_RIGHTS,
              Int(header.cmsg_len) >= controlMessageLength else {
            return nil
        }
        return baseAddress
            .advanced(by: alignedCMSHeaderLength)
            .load(as: Int32.self)
    }

    private static var alignedCMSHeaderLength: Int {
        align32(MemoryLayout<cmsghdr>.size)
    }

    private static var controlMessageLength: Int {
        alignedCMSHeaderLength + MemoryLayout<Int32>.size
    }

    private static var controlSpaceLength: Int {
        alignedCMSHeaderLength + align32(MemoryLayout<Int32>.size)
    }

    private static func align32(_ value: Int) -> Int {
        (value + 3) & ~3
    }
}
