import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissionManager: AccessibilityPermissionManager
    @State private var recheckCount = 0

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
                Text("This window closes by itself once access is granted. Switchboard lives in the menu bar (⊞).")
                    .font(.caption)
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
                    recheckCount += 1
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if recheckCount > 0 && !permissionManager.isTrusted {
                Text("Still not granted. If the Switchboard toggle is already on, it is bound to an old copy of the app: remove Switchboard from the Accessibility list with the − button, then click Open System Settings here to re-register, and turn it on again.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding(48)
        .frame(minWidth: 480, minHeight: 300)
    }
}
