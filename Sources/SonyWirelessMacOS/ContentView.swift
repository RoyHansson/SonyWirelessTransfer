import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("didDismissWelcomeIntro") private var didDismissWelcomeIntro = false

    @State private var isInfoPresented = false
    @State private var isSettingsPresented = false
    @State private var isSetupExpanded = true
    @State private var isReceiverExpanded = true
    @State private var isProgressExpanded = true
    @State private var isLogExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heroCard
                setupCard
                receiverCard
                progressCard
                logCard
            }
            .frame(maxWidth: 600)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(windowBackground.ignoresSafeArea())
    }

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.93, green: 0.84, blue: 0.66), Color(red: 0.80, green: 0.69, blue: 0.52)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)

                    Image(systemName: "camera.aperture")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(inkColor)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sony Wireless Transfer")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(inkColor)

                    Text("Wi-Fi transfer from compatible Sony cameras to macOS. Automatic transfer can be enabled after a first successful pairing and transfer.")
                        .font(.callout)
                        .foregroundStyle(subtleInkColor)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        statusCapsule(
                            title: model.isCameraFound ? "Camera Found" : (model.isAutomaticTransferMonitoring ? "Automatic On" : (model.isManualReceiverActive ? "Receiver On" : "Receiver Off")),
                            color: model.isCameraFound
                                ? Color(red: 0.20, green: 0.60, blue: 0.35)
                                : ((model.isAutomaticTransferMonitoring || model.isManualReceiverActive) ? Color(red: 0.16, green: 0.55, blue: 0.33) : Color(red: 0.35, green: 0.38, blue: 0.43))
                        )
                        statusCapsule(
                            title: model.isTransferring ? "Transferring" : "Ready",
                            color: model.isTransferring ? Color(red: 0.86, green: 0.45, blue: 0.20) : Color(red: 0.35, green: 0.38, blue: 0.43)
                        )
                        statusCapsule(
                            title: model.hasKnownCamera ? "Known Camera" : "Setup Needed",
                            color: model.hasKnownCamera ? Color(red: 0.20, green: 0.45, blue: 0.82) : Color(red: 0.60, green: 0.44, blue: 0.26)
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(22)

            HStack(spacing: 10) {
                headerIconButton(systemName: "info.circle") {
                    isInfoPresented = true
                }
                .popover(isPresented: $isInfoPresented, arrowEdge: .top) {
                    infoPopover
                }

                headerIconButton(systemName: "gearshape") {
                    isSettingsPresented = true
                }
                .popover(isPresented: $isSettingsPresented, arrowEdge: .top) {
                    SettingsView(model: model, showTitle: true)
                        .frame(width: 320)
                        .padding(16)
                }
            }
            .padding(18)

            if !didDismissWelcomeIntro {
                onboardingOverlay
                    .padding(18)
                    .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(heroBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 18, y: 8)
    }

    private var onboardingOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Quick Start", systemImage: "info.circle.fill")
                    .font(.headline)
                    .foregroundStyle(inkColor)

                Spacer()

                Button("OK") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                        didDismissWelcomeIntro = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            quickStartSteps
        }
        .frame(width: 340, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 22, y: 10)
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How It Works")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(inkColor)

            quickStartSteps

            Text("Receiver")
                .font(.headline)
                .foregroundStyle(inkColor)

            Text(receiverExplanationText)
                .font(.callout)
                .foregroundStyle(subtleInkColor)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.headline)
                    .foregroundStyle(inkColor)

                Text("Made by")
                    .font(.callout)
                    .foregroundStyle(subtleInkColor)

                Link("royhansson.se", destination: URL(string: "https://royhansson.se")!)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }

    private var quickStartSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            quickStartRow(number: 1, text: "Plug in the camera via USB.")
            quickStartRow(number: 2, text: "Click Register via USB.")
            quickStartRow(number: 3, text: "Disconnect the cable.")
            quickStartRow(number: 4, text: "On the camera, choose Connect to Computer.")
            quickStartRow(number: 5, text: "Try to find your camera's IP via Start Receiver or enter it manually.")
            quickStartRow(number: 6, text: "Click Transfer Now.")
        }
    }

    private func quickStartRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color(red: 0.20, green: 0.45, blue: 0.82))
                .frame(width: 20, alignment: .leading)

            Text(text)
                .font(.callout)
                .foregroundStyle(inkColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var setupCard: some View {
        collapsibleCard(
            "Setup",
            isExpanded: $isSetupExpanded,
            collapsedSummary: model.hasKnownCamera ? model.knownCameraTitle : model.registrationStatusText
        ) {
            VStack(alignment: .leading, spacing: 16) {
                labeledRow("Destination") {
                    HStack(alignment: .top, spacing: 12) {
                        Text(model.destinationPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(inkColor)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 10) {
                            Button("Choose Folder…") {
                                model.chooseDestinationFolder()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Open Folder") {
                                model.openDestinationFolder()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Divider()

                if model.hasKnownCamera {
                    labeledRow("Known Camera") {
                        knownCameraCard
                    }
                } else {
                    labeledRow("Pair Camera") {
                        pairingCard
                    }
                }
            }
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.registrationStatusText)
                .foregroundStyle(subtleInkColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if model.shouldShowUSBRegistrationAction {
                    Button("Register via USB") {
                        model.registerCameraViaUSB()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    statusCapsule(
                        title: "USB Pairing Complete",
                        color: Color(red: 0.20, green: 0.45, blue: 0.82)
                    )
                }

                Text("After a successful transfer, this camera will be saved for the future.")
                    .font(.callout)
                    .foregroundStyle(subtleInkColor)
            }
        }
    }

    private var knownCameraCard: some View {
        HStack(alignment: .center, spacing: 18) {
            cameraArtwork(width: 118, height: 118, cornerRadius: 20)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.knownCameraTitle)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(inkColor)

                Text(model.knownCameraCaptionText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color(red: 0.20, green: 0.45, blue: 0.82))

                if !model.knownCameraDetailsText.isEmpty {
                    Text(model.knownCameraDetailsText)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(subtleInkColor)
                        .textSelection(.enabled)
                }

                Button("Remove Known Camera") {
                    model.removeKnownCamera()
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(innerPanelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private var receiverCard: some View {
        collapsibleCard(
            "Receiver",
            isExpanded: $isReceiverExpanded,
            collapsedSummary: model.receiverSummaryText
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Receiver")
                            .font(.headline)
                            .foregroundStyle(inkColor)

                        Text(receiverExplanationText)
                            .font(.callout)
                            .foregroundStyle(subtleInkColor)
                    }

                    Spacer()

                    statusCapsule(
                        title: model.receiverStatusLabel,
                        color: model.isCameraFound
                            ? Color(red: 0.20, green: 0.60, blue: 0.35)
                            : ((model.isAutomaticTransferMonitoring || model.isManualReceiverActive) ? Color(red: 0.20, green: 0.45, blue: 0.82) : Color(red: 0.35, green: 0.38, blue: 0.43))
                    )
                }

                Text(model.receiverDetailText)
                    .font(.callout)
                    .foregroundStyle(model.isCameraFound ? Color(red: 0.20, green: 0.60, blue: 0.35) : subtleInkColor)

                Divider()

                HStack(spacing: 10) {
                    Button(model.receiverControlButtonTitle) {
                        model.toggleListening()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!model.isReceiverControlEnabled)

                    Text(model.receiverControlHintText)
                        .font(.callout)
                        .foregroundStyle(model.isCameraFound ? Color(red: 0.20, green: 0.60, blue: 0.35) : subtleInkColor)
                }

                Divider()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic transfer")
                            .font(.headline)
                            .foregroundStyle(inkColor)

                        Text(model.automaticTransferDescription)
                            .font(.callout)
                            .foregroundStyle(subtleInkColor)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { model.autoTransferEnabled },
                        set: { model.autoTransferEnabled = $0 }
                    ))
                    .labelsHidden()
                    .disabled(!model.isAutomaticTransferAvailable)
                }

                Divider()

                labeledRow("Last Detected IP") {
                    HStack(spacing: 12) {
                        Text(model.lastDetectedIP.isEmpty ? "None yet" : model.lastDetectedIP)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(inkColor)
                            .textSelection(.enabled)

                        Spacer()

                        Button("Use Detected IP") {
                            model.useLastDetectedIP()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.lastDetectedIP.isEmpty)
                    }
                }

                labeledRow("Manual Transfer") {
                    HStack(spacing: 12) {
                        TextField("192.168.1.122", text: Binding(
                            get: { model.manualIPAddress },
                            set: { model.manualIPAddress = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                        Button("Transfer Now") {
                            model.transferFromManualIPAddress()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isTransferring)
                    }
                }
            }
        }
    }

    private var progressCard: some View {
        let snapshot = model.transferProgress
        return collapsibleCard(
            "Progress",
            isExpanded: $isProgressExpanded,
            collapsedSummary: model.currentTransferSummary.isEmpty ? "No transfer running." : model.currentTransferSummary
        ) {
            VStack(alignment: .leading, spacing: 14) {
                let progressValue = snapshot.totalFiles == 0 ? 0.0 : Double(snapshot.completedFiles) / Double(snapshot.totalFiles)

                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(Color(red: 0.72, green: 0.53, blue: 0.25))

                Text(model.currentTransferSummary.isEmpty ? "No transfer running." : model.currentTransferSummary)
                    .font(.callout)
                    .foregroundStyle(inkColor)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    statPill(title: "Images", value: "\(snapshot.downloadedImages)")
                    statPill(title: "Movies", value: "\(snapshot.downloadedMovies)")
                    statPill(title: "Skipped", value: "\(snapshot.skippedExisting)")
                    statPill(title: "Files", value: snapshot.totalFiles == 0 ? "0" : "\(snapshot.completedFiles)/\(snapshot.totalFiles)")
                }

                if !snapshot.currentFileName.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Current file: \(snapshot.currentFileName)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(subtleInkColor)

                        if snapshot.currentFileTotalBytes > 0 {
                            ProgressView(value: Double(snapshot.currentFileBytes), total: Double(snapshot.currentFileTotalBytes))
                                .progressViewStyle(.linear)
                                .tint(Color(red: 0.20, green: 0.45, blue: 0.82))
                            Text("\(Self.byteFormatter.string(fromByteCount: Int64(snapshot.currentFileBytes))) / \(Self.byteFormatter.string(fromByteCount: Int64(snapshot.currentFileTotalBytes)))")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(subtleInkColor)
                        }
                    }
                }
            }
        }
    }

    private var logCard: some View {
        collapsibleCard(
            "Log",
            isExpanded: $isLogExpanded,
            collapsedSummary: model.logs.last?.message ?? "No activity yet."
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.logs) { line in
                            Text("[\(Self.formatter.string(from: line.timestamp))] \(line.message)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(inkColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.logBottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 170, maxHeight: 220)
                .onAppear {
                    scrollLogToBottom(using: proxy, animated: false)
                }
                .onChange(of: model.logs.count) { _ in
                    scrollLogToBottom(using: proxy, animated: true)
                }
            }
        }
    }

    private func collapsibleCard<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        collapsedSummary: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(inkColor)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(subtleInkColor)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(innerPanelBackground)
                        )
                }
                .buttonStyle(.plain)
            }

            if isExpanded.wrappedValue {
                content()
            } else {
                Text(collapsedSummary)
                    .font(.callout)
                    .foregroundStyle(subtleInkColor)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 12, y: 6)
    }

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(subtleInkColor)
            content()
        }
    }

    private func headerIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(inkColor)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.82))
                )
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func statusCapsule(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(subtleInkColor)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(inkColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(innerPanelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
    }

    private func cameraArtwork(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(innerPanelBackground)
            .frame(width: width, height: height)
            .overlay(
                Image(systemName: "camera")
                    .font(.system(size: min(width, height) * 0.30, weight: .medium))
                    .foregroundStyle(subtleInkColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
    }

    private func scrollLogToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        guard isLogExpanded else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.logBottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.logBottomID, anchor: .bottom)
        }
    }

    private var receiverExplanationText: String {
        "Scans your local network for the camera. Automatic transfer keeps checking for your saved camera in the background. The camera only appears while it is connected to Wi-Fi through \"Connect to Computer\" in the camera settings."
    }

    private var windowBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 0.97),
                    Color(red: 0.97, green: 0.96, blue: 0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.42))
                .frame(width: 340, height: 340)
                .blur(radius: 42)
                .offset(x: -220, y: -250)

            Circle()
                .fill(Color(red: 0.91, green: 0.85, blue: 0.76).opacity(0.30))
                .frame(width: 260, height: 260)
                .blur(radius: 42)
                .offset(x: 220, y: -180)
        }
    }

    private var inkColor: Color {
        Color(red: 0.13, green: 0.14, blue: 0.17)
    }

    private var subtleInkColor: Color {
        Color(red: 0.38, green: 0.40, blue: 0.45)
    }

    private var heroBackground: Color {
        Color(red: 0.987, green: 0.981, blue: 0.968)
    }

    private var cardBackground: Color {
        Color(red: 0.985, green: 0.987, blue: 0.992)
    }

    private var innerPanelBackground: Color {
        Color(red: 0.970, green: 0.974, blue: 0.980)
    }

    private static let logBottomID = "log-bottom"

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
