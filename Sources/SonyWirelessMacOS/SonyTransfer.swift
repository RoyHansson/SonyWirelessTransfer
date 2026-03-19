import Darwin
import Foundation

struct SonyCameraIdentity: Sendable {
    let cameraName: String?
    let cameraGUID: String?
    let modelHint: String?
}

struct SonyTransferResult: Sendable {
    let output: String
    let downloadedImages: Int
    let downloadedMovies: Int
    let skippedExisting: Int
    let cameraIdentity: SonyCameraIdentity
}

enum SonyTransferError: LocalizedError {
    case destinationMissing
    case invalidIPAddress(String)
    case connectionFailed(String)
    case protocolError(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .destinationMissing:
            return "The destination folder does not exist."
        case .invalidIPAddress(let value):
            return "Invalid camera IP address: \(value)"
        case .connectionFailed(let message):
            return "Could not connect to the camera: \(message)"
        case .protocolError(let message):
            return "Sony PTP/IP transfer failed: \(message)"
        case .fileWriteFailed(let message):
            return "Could not save a transferred file: \(message)"
        }
    }
}

struct SonyTransfer: Sendable {
    private static let sonyInitiatorGUID = Data([
        0xff, 0xff, 0x52, 0x54, 0x00, 0xb6, 0xfd, 0xa9,
        0xff, 0xff, 0x52, 0x3c, 0x28, 0x07, 0xa9, 0x3a,
    ])
    private static let sonyInitiatorName = "Mac"
    private static let ptpipPort: UInt16 = 15740
    private static let connectionRetryWindow: TimeInterval = 20
    private static let socketTimeout: TimeInterval = 20
    private static let probeTimeout: TimeInterval = 2

    func probeCameraAvailability(at ipAddress: String) -> Bool {
        do {
            let socket = try SocketConnection.connect(
                to: ipAddress,
                port: Self.ptpipPort,
                timeout: Self.probeTimeout,
                enableKeepAlive: false
            )
            socket.close()
            return true
        } catch {
            return false
        }
    }

    func transfer(
        from ipAddress: String,
        destinationPath: String,
        progress: (@Sendable (String) -> Void)? = nil,
        progressUpdate: (@Sendable (TransferProgressSnapshot) -> Void)? = nil,
        firstDownloadedFile: (@Sendable (SonyCameraIdentity) -> Void)? = nil,
        completion: @escaping @Sendable (Result<SonyTransferResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.transferSynchronously(
                    from: ipAddress,
                    destinationPath: destinationPath,
                    progress: progress,
                    progressUpdate: progressUpdate,
                    firstDownloadedFile: firstDownloadedFile
                )
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func transferSynchronously(
        from ipAddress: String,
        destinationPath: String,
        progress: (@Sendable (String) -> Void)?,
        progressUpdate: (@Sendable (TransferProgressSnapshot) -> Void)?,
        firstDownloadedFile: (@Sendable (SonyCameraIdentity) -> Void)?
    ) throws -> SonyTransferResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SonyTransferError.destinationMissing
        }

        let rootURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let imagesURL = rootURL.appendingPathComponent("Images", isDirectory: true)
        let moviesURL = rootURL.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moviesURL, withIntermediateDirectories: true)
        progress?("Prepared destination folders:\n- \(imagesURL.path)\n- \(moviesURL.path)")
        progressUpdate?(.init(
            phase: .preparing,
            totalFiles: 0,
            completedFiles: 0,
            currentFileName: "",
            currentFileBytes: 0,
            currentFileTotalBytes: 0,
            downloadedImages: 0,
            downloadedMovies: 0,
            skippedExisting: 0
        ))

        let client = try SonyPTPIPClient(
            ipAddress: ipAddress,
            port: Self.ptpipPort,
            timeout: Self.socketTimeout,
            retryWindow: Self.connectionRetryWindow,
            initiatorGUID: Self.sonyInitiatorGUID,
            initiatorName: Self.sonyInitiatorName
        )

        defer { client.close() }

        progress?("Connecting to Sony camera at \(ipAddress)...")
        progressUpdate?(.init(
            phase: .connecting,
            totalFiles: 0,
            completedFiles: 0,
            currentFileName: "",
            currentFileBytes: 0,
            currentFileTotalBytes: 0,
            downloadedImages: 0,
            downloadedMovies: 0,
            skippedExisting: 0
        ))
        try client.connect()
        let cameraIdentity = client.cameraIdentity
        progress?("Sony PTP/IP command and event channels are open.")
        try client.openSession()
        progress?("PTP session opened.")
        _ = try client.getDeviceInfo()
        progress?("Camera device info read.")
        let mediaObjects = try client.listMediaObjects()
        progress?("Found \(mediaObjects.count) transferable media object(s).")
        progressUpdate?(.init(
            phase: .listing,
            totalFiles: mediaObjects.count,
            completedFiles: 0,
            currentFileName: "",
            currentFileBytes: 0,
            currentFileTotalBytes: 0,
            downloadedImages: 0,
            downloadedMovies: 0,
            skippedExisting: 0
        ))

        var downloadedImages = 0
        var downloadedMovies = 0
        var skippedExisting = 0
        var createdFiles: [String] = []
        var skippedFiles: [String] = []
        var completedFiles = 0
        var didReportFirstDownload = false

        for object in mediaObjects {
            let destinationDirectory: URL
            switch object.category {
            case .image:
                destinationDirectory = imagesURL
            case .movie:
                destinationDirectory = moviesURL
            }

            let resolution = try resolveDestination(for: object, in: destinationDirectory)
            switch resolution {
            case .skipExisting(let url):
                skippedExisting += 1
                completedFiles += 1
                skippedFiles.append(url.lastPathComponent)
                progress?("Skipping existing file \(url.lastPathComponent).")
                progressUpdate?(.init(
                    phase: .transferring,
                    totalFiles: mediaObjects.count,
                    completedFiles: completedFiles,
                    currentFileName: url.lastPathComponent,
                    currentFileBytes: object.size,
                    currentFileTotalBytes: object.size,
                    downloadedImages: downloadedImages,
                    downloadedMovies: downloadedMovies,
                    skippedExisting: skippedExisting
                ))
            case .download(let url):
                progress?("Downloading \(object.filename) to \(url.lastPathComponent)...")
                let data = try client.getObject(handle: object.handle) { receivedBytes, totalBytes in
                    progressUpdate?(.init(
                        phase: .transferring,
                        totalFiles: mediaObjects.count,
                        completedFiles: completedFiles,
                        currentFileName: url.lastPathComponent,
                        currentFileBytes: receivedBytes,
                        currentFileTotalBytes: totalBytes,
                        downloadedImages: downloadedImages,
                        downloadedMovies: downloadedMovies,
                        skippedExisting: skippedExisting
                    ))
                }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    throw SonyTransferError.fileWriteFailed("\(url.path): \(error.localizedDescription)")
                }

                do {
                    try applyTimestampMetadata(from: object, to: url)
                } catch {
                    progress?("Saved \(url.lastPathComponent), but could not apply the camera timestamp: \(error.localizedDescription)")
                }

                if !didReportFirstDownload {
                    didReportFirstDownload = true
                    firstDownloadedFile?(cameraIdentity)
                }

                createdFiles.append(url.lastPathComponent)
                progress?("Saved \(url.lastPathComponent) (\(data.count) bytes).")
                switch object.category {
                case .image:
                    downloadedImages += 1
                case .movie:
                    downloadedMovies += 1
                }
                completedFiles += 1
                progressUpdate?(.init(
                    phase: .transferring,
                    totalFiles: mediaObjects.count,
                    completedFiles: completedFiles,
                    currentFileName: url.lastPathComponent,
                    currentFileBytes: UInt64(data.count),
                    currentFileTotalBytes: UInt64(data.count),
                    downloadedImages: downloadedImages,
                    downloadedMovies: downloadedMovies,
                    skippedExisting: skippedExisting
                ))
            }
        }

        var lines = [
            "Connected to \(ipAddress).",
            "Saved \(downloadedImages) new image(s) to Images.",
            "Saved \(downloadedMovies) new movie(s) to Movies.",
            "Skipped \(skippedExisting) existing file(s).",
        ]

        if !createdFiles.isEmpty {
            lines.append("New files: \(createdFiles.prefix(10).joined(separator: ", "))")
        }
        if !skippedFiles.isEmpty {
            lines.append("Skipped files: \(skippedFiles.prefix(10).joined(separator: ", "))")
        }

        return SonyTransferResult(
            output: lines.joined(separator: "\n"),
            downloadedImages: downloadedImages,
            downloadedMovies: downloadedMovies,
            skippedExisting: skippedExisting,
            cameraIdentity: cameraIdentity
        )
    }

    private func makeClient(ipAddress: String, timeout: TimeInterval, retryWindow: TimeInterval) throws -> SonyPTPIPClient {
        try SonyPTPIPClient(
            ipAddress: ipAddress,
            port: Self.ptpipPort,
            timeout: timeout,
            retryWindow: retryWindow,
            initiatorGUID: Self.sonyInitiatorGUID,
            initiatorName: Self.sonyInitiatorName
        )
    }

    private enum DestinationResolution {
        case skipExisting(URL)
        case download(URL)
    }

    private func applyTimestampMetadata(from object: SonyObjectInfo, to url: URL) throws {
        let creationDate = object.captureDate ?? object.modificationDate
        let modificationDate = object.modificationDate ?? object.captureDate
        guard creationDate != nil || modificationDate != nil else { return }

        var attributes: [FileAttributeKey: Any] = [:]
        if let creationDate {
            attributes[.creationDate] = creationDate
        }
        if let modificationDate {
            attributes[.modificationDate] = modificationDate
        }

        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    private func resolveDestination(for object: SonyObjectInfo, in directory: URL) throws -> DestinationResolution {
        let sanitizedName = sanitizeFilename(object.filename)
        let candidate = directory.appendingPathComponent(sanitizedName, isDirectory: false)

        if let existingSize = fileSize(at: candidate) {
            if existingSize == object.size {
                return .skipExisting(candidate)
            }
            return .download(uniqueURL(for: candidate, expectedSize: object.size))
        }

        return .download(candidate)
    }

    private func uniqueURL(for originalURL: URL, expectedSize: UInt64) -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension
        var counter = 1

        while true {
            let candidateName = pathExtension.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(pathExtension)"
            let candidate = originalURL.deletingLastPathComponent().appendingPathComponent(candidateName, isDirectory: false)
            if let existingSize = fileSize(at: candidate) {
                if existingSize == expectedSize {
                    return candidate
                }
                counter += 1
                continue
            }
            return candidate
        }
    }

    private func fileSize(at url: URL) -> UInt64? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize
        else {
            return nil
        }
        return UInt64(fileSize)
    }

    private func sanitizeFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\")
        let parts = filename.components(separatedBy: invalidCharacters).filter { !$0.isEmpty }
        return parts.isEmpty ? UUID().uuidString : parts.joined(separator: "_")
    }
}

private enum SonyMediaCategory: Sendable {
    case image
    case movie
}

private struct SonyObjectInfo: Sendable {
    let handle: UInt32
    let filename: String
    let size: UInt64
    let objectFormat: UInt16
    let category: SonyMediaCategory
    let captureDate: Date?
    let modificationDate: Date?
}

private final class SonyPTPIPClient {
    private let ipAddress: String
    private let port: UInt16
    private let timeout: TimeInterval
    private let retryWindow: TimeInterval
    private let initiatorGUID: Data
    private let initiatorName: String

    private var commandSocket: SocketConnection?
    private var eventSocket: SocketConnection?
    private var eventPipeID: UInt32 = 0
    private var nextTransactionID: UInt32 = 1

    private(set) var cameraIdentity = SonyCameraIdentity(cameraName: nil, cameraGUID: nil, modelHint: nil)

    init(
        ipAddress: String,
        port: UInt16,
        timeout: TimeInterval,
        retryWindow: TimeInterval,
        initiatorGUID: Data,
        initiatorName: String
    ) throws {
        guard !initiatorGUID.isEmpty else {
            throw SonyTransferError.protocolError("Initiator GUID is empty.")
        }
        self.ipAddress = ipAddress
        self.port = port
        self.timeout = timeout
        self.retryWindow = retryWindow
        self.initiatorGUID = initiatorGUID
        self.initiatorName = initiatorName
    }

    deinit {
        close()
    }

    func connect() throws {
        let deadline = Date().addingTimeInterval(retryWindow)
        while true {
            do {
                let socket = try SocketConnection.connect(to: ipAddress, port: port, timeout: timeout)
                try socket.write(packet: initCommandRequest())
                let packet = try socket.readPacket()
                guard packet.type == .initCommandAck else {
                    throw SonyTransferError.protocolError("Expected INIT_COMMAND_ACK, got packet type \(packet.type.rawValue).")
                }
                guard packet.payload.count >= 20 else {
                    throw SonyTransferError.protocolError("Short INIT_COMMAND_ACK payload.")
                }

                eventPipeID = packet.payload.readUInt32(at: 0)
                cameraIdentity = SonyCameraIdentity(
                    cameraName: decodeNullTerminatedUTF16(packet.payload.count > 20 ? packet.payload.subdata(in: 20..<packet.payload.count) : Data()),
                    cameraGUID: formatGUID(packet.payload.subdata(in: 4..<20)),
                    modelHint: modelHint(from: decodeNullTerminatedUTF16(packet.payload.count > 20 ? packet.payload.subdata(in: 20..<packet.payload.count) : Data()))
                )
                commandSocket = socket

                let eventSocket = try SocketConnection.connect(to: ipAddress, port: port, timeout: timeout)
                let eventInitPayload = Data(fromLE: UInt32(12)) + Data(fromLE: PTPIPPacketType.initEventRequest.rawValue) + Data(fromLE: eventPipeID)
                try eventSocket.write(raw: eventInitPayload)
                let eventPacket = try eventSocket.readPacket()
                guard eventPacket.type == .initEventAck else {
                    throw SonyTransferError.protocolError("Expected INIT_EVENT_ACK, got packet type \(eventPacket.type.rawValue).")
                }
                self.eventSocket = eventSocket
                return
            } catch {
                close()
                if Date() >= deadline {
                    if let transferError = error as? SonyTransferError {
                        throw transferError
                    }
                    throw SonyTransferError.connectionFailed(error.localizedDescription)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    func openSession() throws {
        let response = try executeCommand(opcode: 0x1002, transactionID: 0, parameters: [1], expectsData: false, onDataProgress: nil)
        guard response.responseCode == 0x2001 else {
            throw SonyTransferError.protocolError("OpenSession failed with response 0x\(String(response.responseCode, radix: 16)).")
        }
        nextTransactionID = 1
    }

    func getDeviceInfo() throws -> Data {
        let response = try executeCommand(opcode: 0x1001, transactionID: nextTransaction(), parameters: [], expectsData: true, onDataProgress: nil)
        guard response.responseCode == 0x2001 else {
            throw SonyTransferError.protocolError("GetDeviceInfo failed with response 0x\(String(response.responseCode, radix: 16)).")
        }
        return response.data
    }

    func listMediaObjects() throws -> [SonyObjectInfo] {
        let storageIDsResponse = try executeCommand(opcode: 0x1004, transactionID: nextTransaction(), parameters: [], expectsData: true, onDataProgress: nil)
        guard storageIDsResponse.responseCode == 0x2001 else {
            throw SonyTransferError.protocolError("GetStorageIDs failed with response 0x\(String(storageIDsResponse.responseCode, radix: 16)).")
        }
        _ = try parseUInt32Array(storageIDsResponse.data)

        let handlesResponse = try executeCommand(
            opcode: 0x1007,
            transactionID: nextTransaction(),
            parameters: [0xffffffff, 0x00000000, 0x00000000],
            expectsData: true,
            onDataProgress: nil
        )
        guard handlesResponse.responseCode == 0x2001 else {
            throw SonyTransferError.protocolError("GetObjectHandles failed with response 0x\(String(handlesResponse.responseCode, radix: 16)).")
        }

        let handles = try parseUInt32Array(handlesResponse.data)
        var objects: [SonyObjectInfo] = []
        objects.reserveCapacity(handles.count)

        for handle in handles {
            let infoResponse = try executeCommand(
                opcode: 0x1008,
                transactionID: nextTransaction(),
                parameters: [handle],
                expectsData: true,
                onDataProgress: nil
            )
            guard infoResponse.responseCode == 0x2001 else {
                throw SonyTransferError.protocolError("GetObjectInfo failed for handle 0x\(String(handle, radix: 16)) with response 0x\(String(infoResponse.responseCode, radix: 16)).")
            }

            let metadata = try parseObjectInfo(handle: handle, payload: infoResponse.data)
            guard let category = mediaCategory(for: metadata.filename, objectFormat: metadata.objectFormat) else {
                continue
            }
            objects.append(
                SonyObjectInfo(
                    handle: handle,
                    filename: metadata.filename,
                    size: metadata.size,
                    objectFormat: metadata.objectFormat,
                    category: category,
                    captureDate: metadata.captureDate,
                    modificationDate: metadata.modificationDate
                )
            )
        }

        return objects
    }

    func getObject(handle: UInt32) throws -> Data {
        let response = try executeCommand(
            opcode: 0x1009,
            transactionID: nextTransaction(),
            parameters: [handle],
            expectsData: true,
            onDataProgress: nil
        )
        guard response.responseCode == 0x2001 else {
            throw SonyTransferError.protocolError("GetObject failed for handle 0x\(String(handle, radix: 16)) with response 0x\(String(response.responseCode, radix: 16)).")
        }
        return response.data
    }

    func getObject(handle: UInt32, onDataProgress: @escaping (UInt64, UInt64) -> Void) throws -> Data {
        let response = try executeCommand(
            opcode: 0x1009,
            transactionID: nextTransaction(),
            parameters: [handle],
            expectsData: true,
            onDataProgress: onDataProgress
        )
        guard response.responseCode == 0x2001 else {
            throw SonyTransferError.protocolError("GetObject failed for handle 0x\(String(handle, radix: 16)) with response 0x\(String(response.responseCode, radix: 16)).")
        }
        return response.data
    }

    func close() {
        commandSocket?.close()
        commandSocket = nil
        eventSocket?.close()
        eventSocket = nil
    }

    private func nextTransaction() -> UInt32 {
        let value = nextTransactionID
        nextTransactionID += 1
        return value
    }

    private func initCommandRequest() -> Data {
        var payload = Data(fromLE: PTPIPPacketType.initCommandRequest.rawValue)
        payload.append(initiatorGUID)
        payload.append(initiatorName.data(using: .utf16LittleEndian) ?? Data())
        payload.append(contentsOf: [0x00, 0x00])
        payload.append(Data(fromLE16: 0))
        payload.append(Data(fromLE16: 1))
        return Data(fromLE: UInt32(payload.count + 4)) + payload
    }

    private func executeCommand(
        opcode: UInt16,
        transactionID: UInt32,
        parameters: [UInt32],
        expectsData: Bool,
        onDataProgress: ((UInt64, UInt64) -> Void)?
    ) throws -> CommandResponse {
        guard let commandSocket else {
            throw SonyTransferError.connectionFailed("Command socket is not open.")
        }

        var payload = Data()
        payload.append(Data(fromLE: PTPIPPacketType.commandRequest.rawValue))
        payload.append(Data(fromLE: UInt32(1)))
        payload.append(Data(fromLE16: opcode))
        payload.append(Data(fromLE: transactionID))
        for parameter in parameters {
            payload.append(Data(fromLE: parameter))
        }

        try commandSocket.write(packetPayload: payload)

        var collectedData = Data()
        var expectedLength: UInt32?

        while true {
            let packet = try commandSocket.readPacket()
            switch packet.type {
            case .startData:
                guard packet.payload.count >= 12 else {
                    throw SonyTransferError.protocolError("Short START_DATA payload.")
                }
                let packetTransactionID = packet.payload.readUInt32(at: 0)
                guard packetTransactionID == transactionID else {
                    throw SonyTransferError.protocolError("Unexpected transaction ID in START_DATA.")
                }
                expectedLength = packet.payload.readUInt32(at: 4)
                if let expectedLength {
                    onDataProgress?(UInt64(collectedData.count), UInt64(expectedLength))
                }
            case .data, .endData:
                guard packet.payload.count >= 4 else {
                    throw SonyTransferError.protocolError("Short DATA payload.")
                }
                let packetTransactionID = packet.payload.readUInt32(at: 0)
                guard packetTransactionID == transactionID else {
                    throw SonyTransferError.protocolError("Unexpected transaction ID in DATA payload.")
                }
                collectedData.append(packet.payload.dropFirst(4))
                if let expectedLength {
                    onDataProgress?(UInt64(collectedData.count), UInt64(expectedLength))
                }
            case .commandResponse:
                guard packet.payload.count >= 6 else {
                    throw SonyTransferError.protocolError("Short COMMAND_RESPONSE payload.")
                }
                let responseCode = packet.payload.readUInt16(at: 0)
                let packetTransactionID = packet.payload.readUInt32(at: 2)
                guard packetTransactionID == transactionID else {
                    throw SonyTransferError.protocolError("Unexpected transaction ID in COMMAND_RESPONSE.")
                }

                if expectsData, let expectedLength, UInt32(collectedData.count) != expectedLength {
                    throw SonyTransferError.protocolError("Expected \(expectedLength) bytes of data, received \(collectedData.count).")
                }

                let parameter: UInt32?
                if packet.payload.count >= 10 {
                    parameter = packet.payload.readUInt32(at: 6)
                } else {
                    parameter = nil
                }

                return CommandResponse(responseCode: responseCode, responseParameter: parameter, data: collectedData)
            default:
                throw SonyTransferError.protocolError("Unexpected PTP/IP packet type \(packet.type.rawValue).")
            }
        }
    }

    private func parseUInt32Array(_ data: Data) throws -> [UInt32] {
        guard data.count >= 4 else {
            throw SonyTransferError.protocolError("Short UINT32 array payload.")
        }
        let count = Int(data.readUInt32(at: 0))
        let expectedByteCount = 4 + count * 4
        guard data.count >= expectedByteCount else {
            throw SonyTransferError.protocolError("Truncated UINT32 array payload.")
        }

        var values: [UInt32] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            values.append(data.readUInt32(at: 4 + index * 4))
        }
        return values
    }

    private func parseObjectInfo(handle: UInt32, payload: Data) throws -> (filename: String, size: UInt64, objectFormat: UInt16, captureDate: Date?, modificationDate: Date?) {
        guard payload.count >= 53 else {
            throw SonyTransferError.protocolError("Short ObjectInfo payload for handle 0x\(String(handle, radix: 16)).")
        }

        let objectFormat = payload.readUInt16(at: 4)
        let objectSize = UInt64(payload.readUInt32(at: 8))

        let (rawFilename, nextOffset) = try parsePTPString(in: payload, offset: 52)
        let (captureDateText, finalOffset) = try parsePTPString(in: payload, offset: nextOffset)
        let (modificationDateText, _) = try parsePTPString(in: payload, offset: finalOffset)

        let filename = rawFilename.isEmpty ? "unnamed-\(String(handle, radix: 16))" : rawFilename
        return (
            filename,
            objectSize,
            objectFormat,
            parsePTPDate(captureDateText),
            parsePTPDate(modificationDateText)
        )
    }

    private func parsePTPString(in payload: Data, offset: Int) throws -> (String, Int) {
        guard offset < payload.count else { return ("", offset) }
        let characterCount = Int(payload.readUInt8(at: offset))
        let start = offset + 1
        guard characterCount > 0 else { return ("", start) }

        let byteCount = characterCount * 2
        let end = start + byteCount
        guard end <= payload.count else {
            throw SonyTransferError.protocolError("PTP string overruns ObjectInfo payload.")
        }

        let stringData = payload.subdata(in: start..<(end - 2))
        let value = String(data: stringData, encoding: .utf16LittleEndian) ?? ""
        return (value, end)
    }

    private func parsePTPDate(_ rawValue: String) -> Date? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Self.ptpDateFormatter.date(from: trimmed)
    }

    private func mediaCategory(for filename: String, objectFormat: UInt16) -> SonyMediaCategory? {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["jpg", "jpeg", "arw", "png", "gif", "tif", "tiff", "bmp"]
        let movieExtensions: Set<String> = ["mp4", "mts", "mov", "avi", "m4v", "mpeg", "mpg"]

        if imageExtensions.contains(pathExtension) {
            return .image
        }
        if movieExtensions.contains(pathExtension) {
            return .movie
        }

        switch objectFormat {
        case 0x3801, 0x3808, 0x380b, 0x380d:
            return .image
        case 0x300a, 0x300b, 0x300c, 0x300d:
            return .movie
        default:
            return nil
        }
    }

    private func decodeNullTerminatedUTF16(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        var endIndex = data.count
        var index = 0
        while index + 1 < data.count {
            if data[index] == 0, data[index + 1] == 0 {
                endIndex = index
                break
            }
            index += 2
        }

        let value = String(data: data.prefix(endIndex), encoding: .utf16LittleEndian)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func formatGUID(_ data: Data) -> String? {
        guard data.count == 16 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func modelHint(from cameraName: String?) -> String? {
        guard let cameraName, !cameraName.isEmpty else { return nil }
        if cameraName.localizedCaseInsensitiveContains("ILCE")
            || cameraName.localizedCaseInsensitiveContains("SONY") {
            return "Sony camera"
        }
        return cameraName
    }

    private static let ptpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter
    }()
}

private struct CommandResponse {
    let responseCode: UInt16
    let responseParameter: UInt32?
    let data: Data
}

private enum PTPIPPacketType: UInt32 {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case commandRequest = 6
    case commandResponse = 7
    case startData = 9
    case data = 10
    case endData = 12
}

private final class SocketConnection {
    private let fileDescriptor: Int32
    private var isClosed = false

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        close()
    }

    static func connect(to ipAddress: String, port: UInt16, timeout: TimeInterval, enableKeepAlive: Bool = true) throws -> SocketConnection {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
        }

        do {
            try setTimeout(on: fileDescriptor, timeout: timeout)
            if enableKeepAlive {
                try setKeepAlive(on: fileDescriptor)
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port.bigEndian)

            let conversionResult = ipAddress.withCString { pointer in
                inet_pton(AF_INET, pointer, &address.sin_addr)
            }
            guard conversionResult == 1 else {
                Darwin.close(fileDescriptor)
                throw SonyTransferError.invalidIPAddress(ipAddress)
            }

            let connectResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard connectResult == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(fileDescriptor)
                throw SonyTransferError.connectionFailed(message)
            }

            return SocketConnection(fileDescriptor: fileDescriptor)
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    func write(packet payload: Data) throws {
        try write(raw: payload)
    }

    func write(packetPayload payload: Data) throws {
        try write(raw: Data(fromLE: UInt32(payload.count + 4)) + payload)
    }

    func write(raw data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesSent = 0
            while bytesSent < rawBuffer.count {
                let result = Darwin.send(fileDescriptor, baseAddress.advanced(by: bytesSent), rawBuffer.count - bytesSent, 0)
                if result <= 0 {
                    throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
                }
                bytesSent += result
            }
        }
    }

    func readPacket() throws -> (type: PTPIPPacketType, payload: Data) {
        let header = try readExact(byteCount: 8)
        let totalLength = Int(header.readUInt32(at: 0))
        let rawType = header.readUInt32(at: 4)
        guard totalLength >= 8 else {
            throw SonyTransferError.protocolError("Invalid PTP/IP packet length \(totalLength).")
        }
        guard let type = PTPIPPacketType(rawValue: rawType) else {
            throw SonyTransferError.protocolError("Unknown PTP/IP packet type \(rawType).")
        }
        let payload = try readExact(byteCount: totalLength - 8)
        return (type, payload)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fileDescriptor)
    }

    private func readExact(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRead = 0
            while bytesRead < byteCount {
                let result = Darwin.recv(fileDescriptor, baseAddress.advanced(by: bytesRead), byteCount - bytesRead, 0)
                if result == 0 {
                    throw SonyTransferError.connectionFailed("Socket closed by peer.")
                }
                if result < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SonyTransferError.connectionFailed("Timed out while waiting for the camera.")
                    }
                    throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
                }
                bytesRead += result
            }
        }
        return data
    }

    private static func setTimeout(on fileDescriptor: Int32, timeout: TimeInterval) throws {
        let seconds = Int(timeout.rounded(.down))
        var microseconds = Int((timeout - floor(timeout)) * 1_000_000)
        if microseconds < 0 {
            microseconds = 0
        }
        var timevalValue = timeval(tv_sec: seconds, tv_usec: __darwin_suseconds_t(microseconds))
        let size = socklen_t(MemoryLayout<timeval>.size)

        if setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timevalValue, size) != 0 {
            throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
        }
        if setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timevalValue, size) != 0 {
            throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
        }
    }

    private static func setKeepAlive(on fileDescriptor: Int32) throws {
        var keepAlive: Int32 = 1
        let keepAliveSize = socklen_t(MemoryLayout<Int32>.size)
        if setsockopt(fileDescriptor, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, keepAliveSize) != 0 {
            throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
        }

        var keepAliveSeconds: Int32 = 15
        if setsockopt(fileDescriptor, IPPROTO_TCP, TCP_KEEPALIVE, &keepAliveSeconds, keepAliveSize) != 0 {
            throw SonyTransferError.connectionFailed(String(cString: strerror(errno)))
        }
    }
}

private extension Data {
    init(fromLE value: UInt32) {
        var littleEndian = value.littleEndian
        self.init(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
    }

    init(fromLE16 value: UInt16) {
        var littleEndian = value.littleEndian
        self.init(bytes: &littleEndian, count: MemoryLayout<UInt16>.size)
    }

    func readUInt8(at offset: Int) -> UInt8 {
        self[offset]
    }

    func readUInt16(at offset: Int) -> UInt16 {
        subdata(in: offset..<(offset + 2)).withUnsafeBytes { pointer in
            pointer.load(as: UInt16.self).littleEndian
        }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        subdata(in: offset..<(offset + 4)).withUnsafeBytes { pointer in
            pointer.load(as: UInt32.self).littleEndian
        }
    }
}
