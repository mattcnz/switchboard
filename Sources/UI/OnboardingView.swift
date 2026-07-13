import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissionManager: AccessibilityPermissionManager

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("Accessibility Access Required")
                    .font(.title2.bold())
                Text("Switchboard needs Accessibility access to list and switch between your open windows.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    permissionManager.requestPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Recheck") {
                    permissionManager.recheck()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(48)
        .frame(minWidth: 480, minHeight: 300)
    }
}
