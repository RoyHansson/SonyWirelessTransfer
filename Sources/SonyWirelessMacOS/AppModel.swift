import AppKit
import Foundation

struct LogLine: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}

struct KnownCameraRecord: Codable {
    let ipAddress: String
    let macAddress: String?
    let usn: String?
    let modelHint: String?
    let cameraName: String?
    let cameraGUID: String?
    let lastSeenAt: Date
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: Keys.destinationPath) }
    }

    @Published var manualIPAddress: String {
        didSet { UserDefaults.standard.set(manualIPAddress, forKey: Keys.manualIPAddress) }
    }

    @Published var autoTransferEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoTransferEnabled, forKey: Keys.autoTransferEnabled)
            updateAutomaticTransferMonitoring()
        }
    }

    @Published var launchAtLoginEnabled = false
    @Published private(set) var transferProgress = TransferProgressSnapshot.idle
    @Published private(set) var currentTransferSummary = ""
    @Published private(set) var knownCameraDescription = "No remembered camera yet. Run one manual transfer to save it."
    @Published private(set) var registrationStatusText = "Pair once over USB if needed."
    @Published private(set) var isRegistrationComplete: Bool {
        didSet {
            UserDefaults.standard.set(isRegistrationComplete, forKey: Keys.isRegistrationComplete)
            refreshStatusTexts()
            updateAutomaticTransferMonitoring()
        }
    }

    @Published private(set) var isListening = false
    @Published private(set) var isManualReceiverActive = false
    @Published private(set) var isTransferring = false
    @Published private(set) var lastDetectedIP = ""
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var receiverDetailText = AppModel.receiverIdleText
    @Published private(set) var isCameraFound = false

    var hasKnownCamera: Bool { knownCamera != nil }
    var isAutomaticTransferAvailable: Bool { isRegistrationComplete && knownCamera != nil }
    var isAutomaticTransferMonitoring: Bool { autoTransferEnabled && isAutomaticTransferAvailable }
    var shouldShowUSBRegistrationAction: Bool { !isRegistrationComplete }
    var shouldShowPairingSection: Bool { knownCamera == nil }
    var receiverStatusLabel: String {
        if isCameraFound { return "Camera Found" }
        if isAutomaticTransferMonitoring { return "Automatic" }
        if isManualReceiverActive { return "Searching" }
        return "Receiver Off"
    }
    var receiverSummaryText: String {
        if isCameraFound { return receiverDetailText }
        if isAutomaticTransferMonitoring { return "Automatic search is running in the background." }
        if isManualReceiverActive { return "Searching for the camera on Wi-Fi." }
        return "Receiver is idle."
    }
    var receiverControlButtonTitle: String {
        if isAutomaticTransferMonitoring {
            return "Automatic Search Active"
        }
        return isManualReceiverActive ? "Stop Receiver" : "Start Receiver"
    }
    var isReceiverControlEnabled: Bool {
        !isAutomaticTransferMonitoring
    }
    var receiverControlHintText: String {
        if isAutomaticTransferMonitoring { return "Searching in the background every 10 seconds." }
        if isCameraFound { return "Camera found and ready." }
        if isManualReceiverActive { return "Checking detected addresses." }
        return "Idle."
    }
    var automaticTransferDescription: String {
        isAutomaticTransferAvailable
            ? "Keeps checking for your saved camera every 10 seconds and starts transferring in the background."
            : "Available after the first successful transfer."
    }
    var menuBarSystemImage: String {
        if isTransferring { return "square.and.arrow.down.fill" }
        return "camera"
    }
    var menuBarStatusText: String {
        if isTransferring {
            return currentTransferSummary.isEmpty ? "Transferring…" : currentTransferSummary
        }
        if isAutomaticTransferMonitoring {
            return hasKnownCamera ? "Watching for \(knownCameraTitle)" : "Automatic transfer is waiting for a known camera."
        }
        if isManualReceiverActive {
            return "Manual receiver is running."
        }
        return "Idle"
    }

    var knownCameraTitle: String {
        Self.cameraDisplayName(for: knownCamera) ?? "Sony camera"
    }

    var knownCameraDetailsText: String {
        guard let knownCamera else { return "" }
        return [knownCamera.ipAddress, knownCamera.macAddress].compactMap { $0 }.joined(separator: " • ")
    }

    var knownCameraCaptionText: String {
        "Known Camera"
    }

    private let listener = SSDPListener()
    private let transferRunner = SonyTransfer()
    private let usbRegistration = SonyUSBRegistration()
    private var recentEventDates: [String: Date] = [:]
    private var automaticTransferTimer: DispatchSourceTimer?
    private var pendingAutomaticTransferWorkItem: DispatchWorkItem?
    private var lastKnownCameraAdvertisementAt: Date?
    private var automaticTransferLastAttemptAt: Date?
    private var isProbingKnownCamera = false
    private var isConfirmingDetectedCamera = false
    private var probedAddresses: Set<String> = []
    private var didRememberKnownCameraDuringCurrentTransfer = false
    private var knownCamera: KnownCameraRecord? {
        didSet {
            persistKnownCamera()
            refreshStatusTexts()
            updateAutomaticTransferMonitoring()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        destinationPath = defaults.string(forKey: Keys.destinationPath) ?? Self.defaultDestinationPath()
        manualIPAddress = defaults.string(forKey: Keys.manualIPAddress) ?? ""
        autoTransferEnabled = defaults.object(forKey: Keys.autoTransferEnabled) as? Bool ?? false
        isRegistrationComplete = defaults.object(forKey: Keys.isRegistrationComplete) as? Bool ?? false
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
        knownCamera = Self.loadKnownCamera()
        refreshStatusTexts()

        if !isAutomaticTransferAvailable {
            autoTransferEnabled = false
            defaults.set(false, forKey: Keys.autoTransferEnabled)
        }

        listener.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDiscovery(event)
            }
        }

        appendLog("Choose a folder, then use Connect to Computer on the camera. Automatic transfer can keep watching in the background once a known camera is saved.")
        updateAutomaticTransferMonitoring()
    }

    func refreshDependencyStatus() {
        appendLog("Sony PTP/IP receiver is built in and ready.")
    }

    func toggleListening() {
        guard !isAutomaticTransferMonitoring else { return }
        isManualReceiverActive ? stopListening() : startListening()
    }

    func startListening() {
        guard !isManualReceiverActive else { return }

        isManualReceiverActive = true
        isCameraFound = false
        probedAddresses = []
        isConfirmingDetectedCamera = false
        applyReceiverWaitingState()
        refreshDiscoveryListener(startLog: "Receiver started. Waiting for the camera to appear on Wi-Fi.")
    }

    func stopListening() {
        guard isManualReceiverActive else { return }

        isManualReceiverActive = false
        isCameraFound = false
        applyReceiverWaitingState()
        refreshDiscoveryListener(
            stopLog: isAutomaticTransferMonitoring
                ? "Manual receiver stopped. Automatic transfer is still watching in the background."
                : "Receiver stopped."
        )
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destinationPath, isDirectory: true)

        if panel.runModal() == .OK, let selectedURL = panel.url {
            destinationPath = selectedURL.path
            appendLog("Destination folder set to \(selectedURL.path).")
        }
    }

    func openDestinationFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: destinationPath, isDirectory: true))
    }

    func registerCameraViaUSB() {
        appendLog("Starting USB registration. Connect the camera by USB and approve the admin prompt.")
        usbRegistration.registerCamera { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case .success(let outcome):
                    self?.appendLog(outcome.output)
                    self?.markRegistrationComplete(reason: "USB registration finished.")
                case .failure(let error):
                    self?.appendLog("USB registration failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func removeKnownCamera() {
        autoTransferEnabled = false
        cancelAutomaticTransferScheduling()
        knownCamera = nil
        isRegistrationComplete = false
        isCameraFound = false
        receiverDetailText = Self.receiverIdleText
        lastDetectedIP = ""
        manualIPAddress = ""
        lastKnownCameraAdvertisementAt = nil
        automaticTransferLastAttemptAt = nil
        appendLog("Removed the known camera and reset the pairing state in the app.")
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
            appendLog(launchAtLoginEnabled ? "App will launch automatically at login." : "Launch at login disabled.")
        } catch {
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
            appendLog("Could not update launch at login: \(error.localizedDescription)")
        }
    }

    func useLastDetectedIP() {
        guard !lastDetectedIP.isEmpty else { return }
        manualIPAddress = lastDetectedIP
        appendLog("Manual IP updated to \(lastDetectedIP).")
    }

    func transferFromManualIPAddress() {
        let ipAddress = manualIPAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ipAddress.isEmpty else {
            appendLog("Enter a camera IP address first, or wait for the camera to appear on Wi-Fi.")
            return
        }

        startTransfer(from: ipAddress, reason: "manual request")
    }

    private func handleDiscovery(_ event: SSDPDiscoveryEvent) {
        guard isListening else { return }

        let isKnownMatch = matchesKnownCamera(event)
        if knownCamera != nil, !isKnownMatch {
            return
        }
        if knownCamera == nil, !event.isLikelySony {
            return
        }

        let dedupeKey = "\(event.sourceAddress)|\(event.firstLine)"
        let now = Date()

        if let lastSeen = recentEventDates[dedupeKey], now.timeIntervalSince(lastSeen) < 3 {
            return
        }

        recentEventDates[dedupeKey] = now
        recentEventDates = recentEventDates.filter { now.timeIntervalSince($0.value) < 30 }

        lastDetectedIP = event.sourceAddress
        if manualIPAddress.isEmpty {
            manualIPAddress = event.sourceAddress
        }

        if isKnownMatch {
            let previousAdvertisementAt = lastKnownCameraAdvertisementAt
            rememberKnownCamera(from: event, fallbackIdentity: nil, lastSeenAt: now)
            lastKnownCameraAdvertisementAt = now
            if previousAdvertisementAt == nil || now.timeIntervalSince(previousAdvertisementAt!) > 10 {
                appendLog("Known camera seen at \(event.sourceAddress).")
            }
            if autoTransferEnabled && isAutomaticTransferAvailable {
                handleAutomaticKnownCameraDetection(from: event, lastSeenAt: now)
                return
            }
        } else {
            let label = event.isLikelySony ? "Sony-like device" : "Network device"
            appendLog("\(label) seen at \(event.sourceAddress).")
        }

        confirmDetectedCamera(from: event, shouldAutoTransfer: autoTransferEnabled && isAutomaticTransferAvailable && isKnownMatch)
    }

    private func handleAutomaticKnownCameraDetection(from event: SSDPDiscoveryEvent, lastSeenAt: Date) {
        let ipAddress = event.sourceAddress
        isCameraFound = true
        lastDetectedIP = ipAddress
        manualIPAddress = ipAddress
        receiverDetailText = "\(cameraDisplayName(for: event)) at \(ipAddress)"
        refreshDiscoveryListener()
        scheduleAutomaticTransfer(
            from: ipAddress,
            reason: "automatic Wi-Fi detection",
            earliestStart: lastSeenAt.addingTimeInterval(Self.automaticTransferWarmupDelay)
        )
    }

    private func confirmDetectedCamera(from event: SSDPDiscoveryEvent, shouldAutoTransfer: Bool) {
        let ipAddress = event.sourceAddress
        guard probedAddresses.insert(ipAddress).inserted else { return }
        guard !isConfirmingDetectedCamera else { return }

        isConfirmingDetectedCamera = true
        receiverDetailText = "Checking \(ipAddress)…"
        let transferRunner = transferRunner

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didConfirmCamera = transferRunner.probeCameraAvailability(at: ipAddress)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConfirmingDetectedCamera = false
                guard self.isListening, !self.isCameraFound else { return }

                guard didConfirmCamera else {
                    self.receiverDetailText = Self.receiverScanningText
                    return
                }

                self.lastDetectedIP = ipAddress
                self.manualIPAddress = ipAddress
                self.isCameraFound = true
                self.receiverDetailText = "\(self.cameraDisplayName(for: event)) at \(ipAddress)"
                self.appendLog("Camera found at \(ipAddress).")
                self.isManualReceiverActive = false
                self.refreshDiscoveryListener()

                if shouldAutoTransfer {
                    self.startTransfer(from: ipAddress, reason: "automatic Wi-Fi detection")
                }
            }
        }
    }

    private func startTransfer(from ipAddress: String, reason: String) {
        guard !isTransferring else {
            appendLog("Ignoring transfer request for \(ipAddress) because a transfer is already running.")
            return
        }

        cancelAutomaticTransferScheduling()
        didRememberKnownCameraDuringCurrentTransfer = false
        isTransferring = true
        transferProgress = TransferProgressSnapshot(
            phase: .connecting,
            totalFiles: 0,
            completedFiles: 0,
            currentFileName: "",
            currentFileBytes: 0,
            currentFileTotalBytes: 0,
            downloadedImages: 0,
            downloadedMovies: 0,
            skippedExisting: 0
        )
        currentTransferSummary = "Connecting to \(ipAddress)…"
        appendLog("Starting transfer from \(ipAddress) (\(reason)).")

        transferRunner.transfer(
            from: ipAddress,
            destinationPath: destinationPath,
            progress: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.appendLog(message)
                }
            },
            progressUpdate: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.transferProgress = snapshot
                    self?.currentTransferSummary = Self.describeProgress(snapshot)
                }
            },
            firstDownloadedFile: { [weak self] identity in
                Task { @MainActor [weak self] in
                    self?.rememberKnownCameraAfterFirstDownload(from: ipAddress, identity: identity)
                }
            }
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransferring = false

                switch result {
                case .success(let outcome):
                    self.rememberSuccessfulTransfer(
                        from: ipAddress,
                        outcome: outcome,
                        emitLog: !self.didRememberKnownCameraDuringCurrentTransfer
                    )
                    self.transferProgress = TransferProgressSnapshot(
                        phase: .finished,
                        totalFiles: outcome.downloadedImages + outcome.downloadedMovies + outcome.skippedExisting,
                        completedFiles: outcome.downloadedImages + outcome.downloadedMovies + outcome.skippedExisting,
                        currentFileName: "",
                        currentFileBytes: 0,
                        currentFileTotalBytes: 0,
                        downloadedImages: outcome.downloadedImages,
                        downloadedMovies: outcome.downloadedMovies,
                        skippedExisting: outcome.skippedExisting
                    )
                    self.currentTransferSummary = "Finished. \(outcome.downloadedImages) image(s), \(outcome.downloadedMovies) movie(s), \(outcome.skippedExisting) skipped."
                    let trimmedOutput = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedOutput.isEmpty {
                        self.appendLog("Transfer finished successfully.")
                    } else {
                        self.appendLog("Transfer finished successfully.\n\(trimmedOutput)")
                    }
                case .failure(let error):
                    self.currentTransferSummary = "Transfer failed."
                    self.appendLog("Transfer failed: \(error.localizedDescription)")
                }

                if self.autoTransferEnabled {
                    self.isCameraFound = false
                    self.applyReceiverWaitingState()
                    self.refreshDiscoveryListener()
                }

                self.didRememberKnownCameraDuringCurrentTransfer = false
            }
        }
    }

    private func rememberKnownCameraAfterFirstDownload(from ipAddress: String, identity: SonyCameraIdentity) {
        guard !didRememberKnownCameraDuringCurrentTransfer else { return }

        didRememberKnownCameraDuringCurrentTransfer = true
        manualIPAddress = ipAddress
        rememberKnownCamera(fromIPAddress: ipAddress, identity: identity, sourceUSN: knownCamera?.usn, emitLog: true)
        markRegistrationComplete(reason: "Saved this camera as your Known Camera after the first transferred file.")
    }

    private func rememberSuccessfulTransfer(from ipAddress: String, outcome: SonyTransferResult, emitLog: Bool) {
        manualIPAddress = ipAddress
        rememberKnownCamera(fromIPAddress: ipAddress, identity: outcome.cameraIdentity, sourceUSN: knownCamera?.usn, emitLog: emitLog)
        markRegistrationComplete(reason: "This camera can now transfer wirelessly.")
    }

    private func rememberKnownCamera(from event: SSDPDiscoveryEvent, fallbackIdentity: SonyCameraIdentity?, lastSeenAt: Date) {
        let current = knownCamera
        knownCamera = KnownCameraRecord(
            ipAddress: event.sourceAddress,
            macAddress: event.sourceMACAddress ?? current?.macAddress,
            usn: event.usn ?? current?.usn,
            modelHint: fallbackIdentity?.modelHint ?? Self.modelHint(from: event) ?? current?.modelHint,
            cameraName: fallbackIdentity?.cameraName ?? current?.cameraName,
            cameraGUID: fallbackIdentity?.cameraGUID ?? current?.cameraGUID,
            lastSeenAt: lastSeenAt
        )
    }

    private func rememberKnownCamera(fromIPAddress ipAddress: String, identity: SonyCameraIdentity, sourceUSN: String?, emitLog: Bool) {
        let current = knownCamera
        knownCamera = KnownCameraRecord(
            ipAddress: ipAddress,
            macAddress: NetworkIdentity.lookupMACAddress(for: ipAddress) ?? current?.macAddress,
            usn: sourceUSN ?? current?.usn,
            modelHint: identity.modelHint ?? current?.modelHint,
            cameraName: identity.cameraName ?? current?.cameraName,
            cameraGUID: identity.cameraGUID ?? current?.cameraGUID,
            lastSeenAt: Date()
        )

        if emitLog {
            appendLog("Remembered \(knownCameraTitle) as your Known Camera.")
        }
    }

    private func markRegistrationComplete(reason: String) {
        let wasComplete = isRegistrationComplete
        isRegistrationComplete = true
        if !wasComplete {
            appendLog(reason)
        }
    }

    private func updateAutomaticTransferMonitoring() {
        let shouldMonitor = isAutomaticTransferMonitoring
        let wasMonitoring = automaticTransferTimer != nil

        if shouldMonitor {
            if !wasMonitoring {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + 2, repeating: 10)
                timer.setEventHandler { [weak self] in
                    self?.probeKnownCameraIfNeeded(trigger: "automatic background check")
                }
                automaticTransferTimer = timer
                timer.resume()

                appendLog("Automatic transfer is active. The app will keep checking for your known camera every 10 seconds.")
            }

            isManualReceiverActive = false
            applyReceiverWaitingState()
            refreshDiscoveryListener()
            probeKnownCameraIfNeeded(trigger: wasMonitoring ? "automatic background check" : "automatic startup check")
            return
        }

        if wasMonitoring {
            automaticTransferTimer?.cancel()
            automaticTransferTimer = nil
            cancelAutomaticTransferScheduling()
            appendLog("Automatic transfer is paused.")
        }

        isProbingKnownCamera = false
        isCameraFound = false
        lastKnownCameraAdvertisementAt = nil
        applyReceiverWaitingState()
        refreshDiscoveryListener()
    }

    private func probeKnownCameraIfNeeded(trigger: String) {
        guard autoTransferEnabled, isAutomaticTransferAvailable else { return }
        guard !isTransferring else { return }
        guard let knownCamera else { return }
        guard let lastKnownCameraAdvertisementAt else {
            if isCameraFound {
                isCameraFound = false
                applyReceiverWaitingState()
                refreshDiscoveryListener()
            }
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastKnownCameraAdvertisementAt) <= Self.automaticTransferAdvertisementWindow else {
            if isCameraFound {
                isCameraFound = false
                applyReceiverWaitingState()
                refreshDiscoveryListener()
            }
            cancelAutomaticTransferScheduling()
            return
        }

        isCameraFound = true
        lastDetectedIP = knownCamera.ipAddress
        manualIPAddress = knownCamera.ipAddress
        receiverDetailText = "\(knownCameraTitle) at \(knownCamera.ipAddress)"
        refreshDiscoveryListener()
        scheduleAutomaticTransfer(
            from: knownCamera.ipAddress,
            reason: trigger,
            earliestStart: lastKnownCameraAdvertisementAt.addingTimeInterval(Self.automaticTransferWarmupDelay)
        )
    }

    private func refreshDiscoveryListener(startLog: String? = nil, stopLog: String? = nil) {
        let shouldListen = isManualReceiverActive || isAutomaticTransferMonitoring

        if shouldListen {
            guard !isListening else { return }

            probedAddresses = []
            isConfirmingDetectedCamera = false

            do {
                try listener.start()
                isListening = true
                if let startLog {
                    appendLog(startLog)
                }
            } catch {
                appendLog("Failed to start the receiver: \(error.localizedDescription)")
            }
            return
        }

        guard isListening else { return }
        listener.stop()
        isListening = false
        isConfirmingDetectedCamera = false
        probedAddresses = []
        if let stopLog {
            appendLog(stopLog)
        }
    }

    private func applyReceiverWaitingState() {
        if isCameraFound, let knownCamera {
            receiverDetailText = "\(knownCameraTitle) at \(knownCamera.ipAddress)"
            return
        }

        if isManualReceiverActive {
            receiverDetailText = Self.receiverScanningText
            return
        }

        if isAutomaticTransferMonitoring {
            receiverDetailText = Self.receiverAutomaticText
            return
        }

        receiverDetailText = Self.receiverIdleText
    }

    private func scheduleAutomaticTransfer(from ipAddress: String, reason: String, earliestStart: Date) {
        guard autoTransferEnabled, isAutomaticTransferAvailable else { return }
        guard !isTransferring else { return }
        guard knownCamera?.ipAddress == ipAddress else { return }
        guard pendingAutomaticTransferWorkItem == nil else { return }

        let retryGate = automaticTransferLastAttemptAt?.addingTimeInterval(Self.automaticTransferRetrySpacing) ?? .distantPast
        let scheduledStart = max(earliestStart, retryGate)
        let delay = max(0, scheduledStart.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingAutomaticTransferWorkItem = nil
                guard self.autoTransferEnabled, self.isAutomaticTransferAvailable else { return }
                guard !self.isTransferring else { return }
                guard self.knownCamera?.ipAddress == ipAddress else { return }
                guard let lastKnownCameraAdvertisementAt = self.lastKnownCameraAdvertisementAt else { return }
                guard Date().timeIntervalSince(lastKnownCameraAdvertisementAt) <= Self.automaticTransferAdvertisementWindow else {
                    self.isCameraFound = false
                    self.applyReceiverWaitingState()
                    self.refreshDiscoveryListener()
                    return
                }

                self.automaticTransferLastAttemptAt = Date()
                self.startTransfer(from: ipAddress, reason: reason)
            }
        }

        pendingAutomaticTransferWorkItem = workItem
        if delay > 0.25 {
            appendLog("Known camera is preparing on Wi-Fi. Starting automatic transfer shortly.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelAutomaticTransferScheduling() {
        pendingAutomaticTransferWorkItem?.cancel()
        pendingAutomaticTransferWorkItem = nil
    }

    private func appendLog(_ message: String) {
        logs.append(LogLine(message: message))
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }

    private func refreshStatusTexts() {
        knownCameraDescription = Self.describeKnownCamera(knownCamera, registrationComplete: isRegistrationComplete)

        if knownCamera != nil {
            registrationStatusText = "This camera is already remembered."
        } else if !isRegistrationComplete {
            registrationStatusText = "Pair once over USB if needed."
        } else {
            registrationStatusText = "Run one manual transfer to save this camera."
        }
    }

    private static func defaultDestinationPath() -> String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    private func matchesKnownCamera(_ event: SSDPDiscoveryEvent) -> Bool {
        guard let knownCamera else { return false }
        if let knownMAC = knownCamera.macAddress, let sourceMAC = event.sourceMACAddress {
            return knownMAC.caseInsensitiveCompare(sourceMAC) == .orderedSame
        }
        if let knownUSN = knownCamera.usn, let eventUSN = event.usn {
            return knownUSN == eventUSN
        }
        return knownCamera.ipAddress == event.sourceAddress
    }

    private func persistKnownCamera() {
        if let knownCamera, let data = try? JSONEncoder().encode(knownCamera) {
            UserDefaults.standard.set(data, forKey: Keys.knownCamera)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.knownCamera)
        }
    }

    private static func loadKnownCamera() -> KnownCameraRecord? {
        guard let data = UserDefaults.standard.data(forKey: Keys.knownCamera) else { return nil }
        return try? JSONDecoder().decode(KnownCameraRecord.self, from: data)
    }

    private static func describeKnownCamera(_ camera: KnownCameraRecord?, registrationComplete: Bool) -> String {
        guard let camera else {
            return registrationComplete
                ? "No remembered camera yet. Run one manual transfer to save it."
                : "No remembered camera yet. Complete the USB step, then run one manual transfer."
        }

        let name = cameraDisplayName(for: camera) ?? "Sony camera"
        if let macAddress = camera.macAddress {
            return "\(name) at \(camera.ipAddress) (\(macAddress))"
        }
        return "\(name) at \(camera.ipAddress)"
    }

    private static func cameraDisplayName(for camera: KnownCameraRecord?) -> String? {
        guard let rawName = camera?.cameraName ?? camera?.modelHint else { return nil }
        return cameraDisplayName(from: rawName)
    }

    private static func cameraDisplayName(from rawName: String?) -> String? {
        guard let rawName else { return nil }
        let normalized = rawName.uppercased()

        if normalized.contains("ILCE-") || normalized.contains("SONY") {
            return "Sony camera"
        }

        if rawName.range(of: #"^A\d{3,4}$"#, options: .regularExpression) != nil {
            return "Sony camera"
        }

        return rawName
    }

    private static func modelHint(from event: SSDPDiscoveryEvent) -> String? {
        let candidates = [event.server, event.usn, event.nt, event.summary]
        for candidate in candidates.compactMap({ $0 }) {
            if candidate.localizedCaseInsensitiveContains("ILCE") || candidate.localizedCaseInsensitiveContains("SONY") {
                return "Sony camera"
            }
        }
        return event.isLikelySony ? "Sony camera" : nil
    }

    private func cameraDisplayName(for event: SSDPDiscoveryEvent) -> String {
        if let rememberedName = Self.cameraDisplayName(for: knownCamera) {
            return rememberedName
        }
        if let eventName = Self.cameraDisplayName(from: Self.modelHint(from: event)) {
            return eventName
        }
        return "Sony camera"
    }

    private static func describeProgress(_ snapshot: TransferProgressSnapshot) -> String {
        switch snapshot.phase {
        case .idle:
            return ""
        case .connecting:
            return "Connecting to camera…"
        case .preparing:
            return "Preparing destination…"
        case .listing:
            return snapshot.totalFiles > 0 ? "Found \(snapshot.totalFiles) media file(s)." : "Listing files…"
        case .transferring:
            let total = snapshot.totalFiles == 0 ? "?" : "\(snapshot.totalFiles)"
            let current = snapshot.currentFileName.isEmpty ? "" : " Current: \(snapshot.currentFileName)"
            return "Transferred \(snapshot.completedFiles) / \(total).\(current)"
        case .finished:
            return "Transfer finished."
        }
    }

    private static let receiverIdleText = "Automatic transfer is off."
    private static let receiverScanningText = "Scanning your local network for the camera…"
    private static let receiverAutomaticText = "Automatic transfer is watching for your saved camera every 10 seconds."
    private static let automaticTransferWarmupDelay: TimeInterval = 2.5
    private static let automaticTransferAdvertisementWindow: TimeInterval = 20
    private static let automaticTransferRetrySpacing: TimeInterval = 8

    private enum Keys {
        static let destinationPath = "destinationPath"
        static let manualIPAddress = "manualIPAddress"
        static let autoTransferEnabled = "autoTransferEnabled"
        static let isRegistrationComplete = "isRegistrationComplete"
        static let knownCamera = "knownCamera"
    }
}
