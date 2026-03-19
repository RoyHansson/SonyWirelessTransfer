import Foundation

enum NetworkIdentity {
    private struct CacheEntry {
        let macAddress: String?
        let expiresAt: Date
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 60

    static func lookupMACAddress(for ipAddress: String) -> String? {
        let now = Date()
        if let cachedEntry = cachedEntry(for: ipAddress, now: now) {
            return cachedEntry.macAddress
        }

        let result = runARP(for: ipAddress)
        storeCacheEntry(for: ipAddress, macAddress: result, now: now)
        return result
    }

    private static func runARP(for ipAddress: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ipAddress]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting

        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        do {
            try process.run()
            try? writeHandle.close()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = String(decoding: readHandle.readDataToEndOfFile(), as: UTF8.self)
        let pattern = #"(([0-9a-f]{1,2}:){5}[0-9a-f]{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard
            let match = regex.firstMatch(in: output, options: [], range: range),
            let resultRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }

        return output[resultRange].lowercased()
    }

    private static func cachedEntry(for ipAddress: String, now: Date) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let entry = cache[ipAddress], entry.expiresAt > now {
            return entry
        }

        cache[ipAddress] = nil
        return nil
    }

    private static func storeCacheEntry(for ipAddress: String, macAddress: String?, now: Date) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        cache[ipAddress] = CacheEntry(macAddress: macAddress, expiresAt: now.addingTimeInterval(cacheTTL))
        if cache.count > 256 {
            cache = cache.filter { $0.value.expiresAt > now }
        }
    }
}
