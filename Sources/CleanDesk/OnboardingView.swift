import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var step: Step = .desktop
    @State private var requestedAccess = false
    @State private var query = ""
    @State private var catalog: [SavedApplication] = []
    @State private var isLoading = true
    @FocusState private var searchFocused: Bool

    private enum Step { case desktop, apps }
    private var palette: PanelPalette { PanelPalette(colorScheme: colorScheme) }
    private var desktopAccessReady: Bool { store.cleanDesktopEnabled && !store.desktopNeedsAccess }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleApps: [SavedApplication] {
        if searchText.isEmpty && !store.onboardingApps.isEmpty { return store.onboardingApps }
        return catalog.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: CleanDeskIcon.image(size: 18))
                    .renderingMode(.template)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                Text(store.isRecoveringSelection ? "Restore app selection" : "Set up Clean Desk")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !store.isRecoveringSelection {
                    Text(step == .desktop ? "1 of 2" : "2 of 2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .padding(PanelLayout.inset)

            if step == .desktop && !store.isRecoveringSelection { desktopStep } else { appsStep }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: store.cleanDesktopEnabled) { _, enabled in
            if enabled && !store.desktopNeedsAccess && requestedAccess && step == .desktop {
                requestedAccess = false
                step = .apps
            }
        }
    }

    private var desktopStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(palette.accent)
                    .frame(width: 104, height: 94)
                    .background(PanelSurface(tint: palette.accent, cornerRadius: 24))
                Image(systemName: desktopAccessReady ? "checkmark" : "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PanelPalette.ink)
                    .frame(width: 32, height: 32)
                    .background(PanelPalette.mint, in: Circle())
                    .offset(x: 6, y: 6)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 26)

            Text("A cleaner desktop")
                .font(.system(size: 23, weight: .semibold))
                .padding(.bottom, 10)
            Text("Move desktop files to trash when you clean.\nHidden files and folders stay put.")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)

            Button {
                if desktopAccessReady {
                    step = .apps
                } else {
                    requestedAccess = true
                    store.setCleanDesktopEnabled(true)
                }
            } label: {
                HStack(spacing: 8) {
                    if store.isGrantingDesktopAccess {
                        ProgressView().controlSize(.small)
                    }
                    Text(desktopAccessReady ? "Continue" : "Allow desktop access")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity).frame(height: 48)
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(CleanDeskButtonStyle())
            .disabled(store.isGrantingDesktopAccess)

            Button {
                requestedAccess = false
                store.setCleanDesktopEnabled(false)
                step = .apps
            } label: {
                Text("Not now")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AppRowStyle(tint: palette.accent))
            .disabled(store.isGrantingDesktopAccess)
            .padding(.top, 6)
        }
        .padding(.horizontal, PanelLayout.inset)
        .padding(.bottom, PanelLayout.inset)
    }

    private var appsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Will be open")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(store.isRecoveringSelection
                 ? "Your saved selection could not be read. Choose apps again to enable cleanup."
                 : "Choose the apps to keep open when you clean.")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .padding(.top, 6)
                .padding(.bottom, 18)

            searchField
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: PanelLayout.rowSpacing) {
                    ForEach(visibleApps) { app in appRow(app) }
                    if visibleApps.isEmpty {
                        if isLoading {
                            ProgressView().controlSize(.small).padding(.vertical, 20)
                        } else {
                            Text(searchText.isEmpty ? "Search for an app to get started." : "No results")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                if !store.isRecoveringSelection {
                    Button { step = .desktop } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 86, height: 48)
                            .background(PanelSurface(tint: palette.surface))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(AppRowStyle(tint: palette.accent))
                }
                Button(action: store.finishOnboarding) {
                    Text(store.isRecoveringSelection ? "Save selection" : "Get started")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(CleanDeskButtonStyle())
                .disabled(store.isGrantingDesktopAccess)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, PanelLayout.inset)
        .padding(.bottom, PanelLayout.inset)
        .task {
            guard isLoading else { return }
            let discovered = await Task.detached(priority: .userInitiated) { AppCatalog.discover() }.value
            guard !Task.isCancelled else { return }
            var byID = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for app in store.onboardingApps where byID[app.id] == nil { byID[app.id] = app }
            catalog = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            isLoading = false
            if store.onboardingApps.isEmpty { searchFocused = true }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondaryText)
            TextField("Search", text: $query)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AppRowStyle(tint: palette.accent, cornerRadius: 8))
            }
        }
        .padding(.horizontal, PanelLayout.rowInset)
        .frame(height: 40)
        .background(PanelSurface(tint: palette.surface))
        .overlay {
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                .strokeBorder(searchFocused ? palette.accent.opacity(0.65) : palette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func appRow(_ app: SavedApplication) -> some View {
        let selected = store.onboardingApps.contains { $0.id == app.id }
        return Button { store.toggleOnboardingApplication(app) } label: {
            HStack(spacing: 11) {
                AppGlyph(image: app.icon)
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                RowAction(symbol: selected ? "checkmark" : "plus", tint: palette.accent, filled: selected)
            }
            .padding(.horizontal, PanelLayout.rowInset)
            .frame(height: PanelLayout.rowHeight)
            .background(PanelSurface(tint: selected ? palette.accent : palette.surface))
            .contentShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius))
        }
        .buttonStyle(AppRowStyle(tint: palette.accent))
    }
}
