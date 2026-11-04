import Darwin
import Foundation
import NetworkExtension

final class V2SPacketFlowBridge {
    private let packetFlow: NEPacketTunnelFlow
    let appFileDescriptor: Int32
    let engineFileDescriptor: Int32
    private let queue = DispatchQueue(label: "ca.irisbuddy.v2s.packet-flow", qos: .userInitiated)
    private var readSource: DispatchSourceRead?
    private var stopped = false
    private let lock = NSLock()

    init(packetFlow: NEPacketTunnelFlow) throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            throw POSIXError(.ENOTSUP)
        }
        appFileDescriptor = pair[0]
        engineFileDescriptor = pair[1]
        self.packetFlow = packetFlow
        var receiveBuffer: Int32 = 2 * 1024 * 1024
        _ = setsockopt(appFileDescriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(engineFileDescriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: appFileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.writeReturnedPackets() }
        source.setCancelHandler { [appFileDescriptor, engineFileDescriptor] in
            Darwin.close(appFileDescriptor)
            Darwin.close(engineFileDescriptor)
        }
        readSource = source
        source.resume()
        readAppPackets()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        readSource?.cancel()
        readSource = nil
    }

    private func readAppPackets() {
        lock.lock()
        let shouldContinue = !stopped
        lock.unlock()
        guard shouldContinue else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.lock.lock()
            let active = !self.stopped
            self.lock.unlock()
            guard active else { return }
            for packet in packets {
                packet.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    _ = Darwin.send(self.appFileDescriptor, base, bytes.count, 0)
                }
            }
            self.readAppPackets()
        }
    }

    private func writeReturnedPackets() {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(appFileDescriptor, bytes.baseAddress, bytes.count, 0)
            }
            if count <= 0 { return }
            let packet = Data(buffer.prefix(count))
            let version = packet.first.map { $0 >> 4 }
            let family = version == 6 ? AF_INET6 : AF_INET
            _ = packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
        }
    }
}
