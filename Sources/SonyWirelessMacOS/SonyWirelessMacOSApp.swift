import SwiftUI

@main
struct SonyWirelessMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(model: model)
                .preferredColorScheme(.light)
                .frame(minWidth: 620, idealWidth: 620, maxWidth: 620, minHeight: 620)
                .background(
                    WindowSizingAccessor(
                        width: 620,
                        height: 620,
                        minHeight: 620
                    )
                )
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Sony Wireless Transfer", systemImage: model.menuBarSystemImage) {
            MenuBarContent(
                model: model,
                requestFullQuit: { appDelegate.requestFullQuit() }
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Choose Destination Folder") {
                    model.chooseDestinationFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }

    static let mainWindowID = "main-window"
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var allowsTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard allowsTermination else {
            for window in sender.windows {
                window.orderOut(nil)
            }
            sender.hide(nil)
            return .terminateCancel
        }

        return .terminateNow
    }

    @MainActor
    func requestFullQuit() {
        allowsTermination = true
        NSApp.terminate(nil)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    let requestFullQuit: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sony Wireless Transfer")
                    .font(.headline)

                Text(model.menuBarStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.hasKnownCamera {
                Text("Known camera: \(model.knownCameraTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Automatic Transfer", isOn: Binding(
                get: { model.autoTransferEnabled },
                set: { model.autoTransferEnabled = $0 }
            ))
            .disabled(!model.isAutomaticTransferAvailable)

            Button("Open Window") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SonyWirelessMacOSApp.mainWindowID)
            }

            Button("Quit Sony Wireless Transfer") {
                requestFullQuit()
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

private struct WindowSizingAccessor: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let minHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            window.minSize = NSSize(width: width, height: minHeight)
            window.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)

            guard !context.coordinator.didApplyInitialSize else { return }
            context.coordinator.didApplyInitialSize = true
            window.setContentSize(NSSize(width: width, height: height))
        }
    }

    final class Coordinator {
        var didApplyInitialSize = false
    }
}
