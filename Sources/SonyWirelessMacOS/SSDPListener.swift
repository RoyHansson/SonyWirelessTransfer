import Foundation
import Darwin

struct SSDPDiscoveryEvent: Sendable {
    let sourceAddress: String
    let sourceMACAddress: String?
    let firstLine: String
    let summary: String
    let isLikelySony: Bool
    let sonyConfidence: Int
    let location: String?
    let server: String?
    let usn: String?
    let nt: String?
}

enum SSDPListenerError: LocalizedError {
    case socketCreationFailed
    case bindFailed(String)
    case membershipFailed(String)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Could not create the UDP socket."
        case .bindFailed(let message):
            return "Could not bind the UDP socket: \(message)"
        case .membershipFailed(let message):
            return "Could not join the SSDP multicast group: \(message)"
        }
    }
}

final class SSDPListener: @unchecked Sendable {
    var onEvent: (@Sendable (SSDPDiscoveryEvent) -> Void)?

    private let queue = DispatchQueue(label: "SonyWirelessMacOS.SSDPListener")
    private var socketFileDescriptor: Int32 = -1
    private var isRunning = false

    func start() throws {
        guard socketFileDescriptor == -1 else { return }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw SSDPListenerError.socketCreationFailed
        }

        do {
            try configureSocket(fd)
        } catch {
            close(fd)
            throw error
        }

        socketFileDescriptor = fd
        isRunning = true

        queue.async { [weak self] in
            self?.receiveLoop()
        }
    }

    func stop() {
        isRunning = false

        if socketFileDescriptor != -1 {
            close(socketFileDescriptor)
            socketFileDescriptor = -1
        }
    }

    private func configureSocket(_ fd: Int32) throws {
        var reuseAddress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var reusePort: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reusePort, socklen_t(MemoryLayout<Int32>.size))

        var receiveTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1900).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw SSDPListenerError.bindFailed(String(cString: strerror(errno)))
        }

        var membership = ip_mreq(
            imr_multiaddr: in_addr(s_addr: inet_addr("239.255.255.250")),
            imr_interface: in_addr(s_addr: INADDR_ANY)
        )

        let membershipResult = setsockopt(
            fd,
            IPPROTO_IP,
            IP_ADD_MEMBERSHIP,
            &membership,
            socklen_t(MemoryLayout<ip_mreq>.size)
        )

        guard membershipResult == 0 else {
            throw SSDPListenerError.membershipFailed(String(cString: strerror(errno)))
        }
    }

    private func receiveLoop() {
        while isRunning, socketFileDescriptor != -1 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var sourceStorage = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let bytesRead = withUnsafeMutablePointer(to: &sourceStorage) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    recvfrom(
                        socketFileDescriptor,
                        &buffer,
                        buffer.count,
                        0,
                        socketAddress,
                        &sourceLength
                    )
                }
            }

            if bytesRead > 0 {
                let payload = String(decoding: buffer.prefix(Int(bytesRead)), as: UTF8.self)
                let event = Self.parseEvent(
                    payload: payload,
                    sourceAddress: Self.hostName(from: sourceStorage, length: sourceLength) ?? "unknown"
                )
                onEvent?(event)
                continue
            }

            if bytesRead == 0 {
                continue
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            }

            if !isRunning || socketFileDescriptor == -1 {
                break
            }
        }
    }

    private static func parseEvent(payload: String, sourceAddress: String) -> SSDPDiscoveryEvent {
        let normalizedPayload = payload.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedPayload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstLine = lines.first ?? "(empty packet)"
        let headers = parseHeaders(lines: lines)
        let location = headers["location"]
        let server = headers["server"]
        let usn = headers["usn"]
        let nt = headers["nt"] ?? headers["st"]
        let lowercasedPayload = normalizedPayload.lowercased()

        var sonyConfidence = 0
        if lowercasedPayload.contains("ilce-") || lowercasedPayload.contains("nex-") || lowercasedPayload.contains("dsc-") {
            sonyConfidence += 4
        }
        if lowercasedPayload.contains("sony") || lowercasedPayload.contains("x-sony") || lowercasedPayload.contains("urn:schemas-sony-com") {
            sonyConfidence += 3
        }
        if lowercasedPayload.contains("urn:microsoft-com:device:mtp:1") || lowercasedPayload.contains("mtpnullservice") {
            sonyConfidence += 3
        }
        if (location ?? "").lowercased().contains("devicedescription.xml") {
            sonyConfidence += 1
        }
        if sourceAddress.hasPrefix("192.168.") {
            sonyConfidence += 1
        }

        let isLikelySony = sonyConfidence >= 4
        let sourceMACAddress = NetworkIdentity.lookupMACAddress(for: sourceAddress)
        let summaryParts = [
            firstLine,
            location.map { "LOCATION: \($0)" },
            server.map { "SERVER: \($0)" },
            usn.map { "USN: \($0)" },
            sourceMACAddress.map { "MAC: \($0)" },
        ].compactMap { $0 }
        let summary = summaryParts.joined(separator: " | ")

        return SSDPDiscoveryEvent(
            sourceAddress: sourceAddress,
            sourceMACAddress: sourceMACAddress,
            firstLine: firstLine,
            summary: summary,
            isLikelySony: isLikelySony,
            sonyConfidence: sonyConfidence,
            location: location,
            server: server,
            usn: usn,
            nt: nt
        )
    }

    private static func parseHeaders(lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func hostName(from storage: sockaddr_storage, length: socklen_t) -> String? {
        var storage = storage
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getnameinfo(
                    socketAddress,
                    length,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }

        guard result == 0 else { return nil }
        let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
