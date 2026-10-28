import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: AppStore
    let done: () -> Void
    @StateObject private var launchAtLogin = LaunchAtLoginSettings()
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette { PanelPalette(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            PanelPageHeader(title: "Settings", back: done)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { store.cleanDesktopEnabled }, set: store.setCleanDesktopEnabled)) {
                        settingLabel("Move desktop files to trash")
                    }
                    .disabled(store.isCleaning || store.isGrantingDesktopAccess)
                    .pointingHand(isEnabled: !store.isCleaning && !store.isGrantingDesktopAccess)

                    if store.desktopNeedsAccess {
                        Button("Grant Desktop access…", action: store.grantDesktopAccess)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accent)
                            .padding(.bottom, 8)
                            .disabled(store.isCleaning || store.isGrantingDesktopAccess)
                            .pointingHand(isEnabled: !store.isCleaning && !store.isGrantingDesktopAccess)
                    }

                    Toggle(isOn: Binding(get: { launchAtLogin.enabled }, set: launchAtLogin.setEnabled)) {
                        settingLabel("Launch app on start")
                    }
                    .pointingHand()

                    if launchAtLogin.requiresApproval {
                        Text("Allow Clean Desk in Login Items to launch it automatically.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Login Items…", action: launchAtLogin.openSystemSettings)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.accent)
                            .pointingHand()
                    }

                    if let error = launchAtLogin.errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .padding(.horizontal, PanelLayout.inset)
                .padding(.vertical, PanelLayout.sectionSpacing)
            }
        }
        .background(PanelBackground())
        .onExitCommand(perform: done)
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
    }
}
