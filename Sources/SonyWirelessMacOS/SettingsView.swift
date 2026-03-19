import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var showTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showTitle {
                Text("Settings")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color(red: 0.13, green: 0.14, blue: 0.17))
            }

            Toggle("Start Sony Wireless Transfer when I log in", isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLoginEnabled($0) }
            ))

            Text("Launch automatically after login.")
                .font(.callout)
                .foregroundStyle(Color(red: 0.38, green: 0.40, blue: 0.45))
        }
        .padding(20)
        .frame(width: showTitle ? 360 : 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.985, green: 0.987, blue: 0.992))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}
