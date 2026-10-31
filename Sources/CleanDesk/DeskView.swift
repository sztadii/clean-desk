import AppKit
import SwiftUI

struct DeskView: View {
    @ObservedObject var store: AppStore
    let quit: () -> Void
    @State private var page: Page = .dashboard
    @Environment(\.colorScheme) private var colorScheme

    private var palette: PanelPalette { PanelPalette(colorScheme: colorScheme) }
    private enum Page { case dashboard, apps, settings }
    private var accent: Color { palette.accent }
    private var danger: Color { palette.danger }
    private var keptApps: [SavedApplication] {
        store.protectedApps
    }
    private var closingApps: [ManagedApplication] {
        store.applications.filter { !store.isProtected($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.needsOnboarding {
                    OnboardingView(store: store)
                } else {
                    switch page {
                    case .dashboard:
                        dashboard
                    case .apps:
                        AppPickerView(store: store) { page = .dashboard }
                    case .settings:
                        SettingsView(store: store) { page = .dashboard }
                    }
                }
            }
            reportBanner
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height)
        .background(PanelBackground())
        .tint(accent)
        .contentShape(Rectangle())
        .onChange(of: store.isCleaning) { _, isCleaning in
            if isCleaning { page = .dashboard }
        }
        .contextMenu {
            Button("Keep favourites") { cleanDesk() }
                .disabled(!store.canClean)
            Button("Close all", role: .destructive) { cleanDesk(all: true) }
                .disabled(!store.canCleanAll)
            Divider()
            Button("Quit", action: quit)
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            toolbar

            ScrollView {
                VStack(spacing: PanelLayout.sectionSpacing) {
                    VStack(spacing: keptApps.isEmpty ? 4 : PanelLayout.headerSpacing) {
                        sectionHeading("Favourites", count: keptApps.count, isKept: true)
                        VStack(spacing: PanelLayout.rowSpacing) {
                            ForEach(keptApps) { app in savedRow(app) }
                            if keptApps.isEmpty {
                                emptyState("No apps selected")
                            }
                        }
                    }

                    if !closingApps.isEmpty {
                        VStack(spacing: PanelLayout.headerSpacing) {
                            sectionHeading("Other open apps", count: closingApps.count, isKept: false)
                            VStack(spacing: PanelLayout.rowSpacing) {
                                ForEach(closingApps) { app in closingRow(app) }
                            }
                        }
                    }
                }
                .padding(.horizontal, PanelLayout.inset).padding(.bottom, PanelLayout.inset)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var reportBanner: some View {
        Group {
            if let report = store.report, !report.isSuccess {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(danger)
                            Text(report.message)
                                .font(.system(size: 11)).foregroundStyle(danger).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button(action: store.dismissReport) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(danger)
                                .frame(width: 28, height: 28)
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(AppRowStyle(tint: danger, cornerRadius: 7))
                    }

                    if report.desktopAccessDenied {
                        Button(action: store.grantDesktopAccess) {
                            Text("Grant Desktop access…")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .pointingHand(isEnabled: !store.isCleaning && !store.isGrantingDesktopAccess)
                        .disabled(store.isCleaning || store.isGrantingDesktopAccess)
                    }
                }
                .padding(10)
                .background(PanelSurface(tint: danger))
                .padding(.horizontal, PanelLayout.inset).padding(.bottom, PanelLayout.inset)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: PanelLayout.headerSpacing) {
            cleanButton("Keep favourites", all: false)
            cleanButton("Close all", all: true)

            Button { page = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(AppRowStyle(tint: accent, cornerRadius: 8))
            .disabled(store.isCleaning)
        }
        .padding(PanelLayout.inset)
    }

    private func cleanButton(_ title: String, all: Bool) -> some View {
        Button { cleanDesk(all: all) } label: {
            HStack(spacing: 6) {
                Image(systemName: all ? "trash" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
                .frame(maxWidth: .infinity).frame(height: 50)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(CleanDeskButtonStyle(isDestructive: all))
        .disabled(all ? !store.canCleanAll : !store.canClean)
    }

    private func sectionHeading(_ title: String, count: Int, isKept: Bool) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: .semibold))
                CountBadge(count: count, tint: isKept ? accent : danger)
            }
            Spacer()
            if isKept {
                Button(action: chooseApplication) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 72, height: 36)
                        .background(PanelSurface(tint: accent, cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(AppRowStyle(tint: accent, cornerRadius: 10)).disabled(store.isCleaning)
            }
        }
        .foregroundStyle(isKept ? accent : danger)
        .frame(height: PanelLayout.headerHeight)
    }

    private func savedRow(_ app: SavedApplication) -> some View {
        Button { store.removeProtection(app) } label: {
            HStack(spacing: 11) {
                AppGlyph(image: app.icon)
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                if store.needsOpening(app) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                            .accessibilityHidden(true)
                        Text("Will open")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(accent)
                    .fixedSize()
                }
                RowAction(symbol: "minus", tint: accent)
            }
            .padding(.horizontal, PanelLayout.rowInset).frame(height: PanelLayout.rowHeight)
            .background(PanelSurface(tint: accent))
            .contentShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
        }
        .buttonStyle(AppRowStyle(tint: accent))
        .disabled(store.isCleaning)
    }

    private func closingRow(_ app: ManagedApplication) -> some View {
        Button { store.toggleProtection(app) } label: {
            HStack(spacing: 11) {
                AppGlyph(image: app.icon)
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                RowAction(symbol: "plus", tint: danger)
            }
            .padding(.horizontal, PanelLayout.rowInset).frame(height: PanelLayout.rowHeight)
            .background(PanelSurface(tint: danger))
            .contentShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
        }
        .buttonStyle(AppRowStyle(tint: danger))
        .disabled(store.isCleaning)
    }

    private func chooseApplication() { page = .apps }

    private func cleanDesk(all: Bool = false) {
        page = .dashboard
        store.clean(all: all)
    }

    private func emptyState(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
    }

}
