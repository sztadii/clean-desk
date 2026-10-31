import AppKit
import SwiftUI

struct AppPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: AppStore
    let done: () -> Void
    @State private var catalog: [SavedApplication] = []
    @State private var query = ""
    @State private var isLoading = true
    @FocusState private var isSearchFocused: Bool

    private var palette: PanelPalette { PanelPalette(colorScheme: colorScheme) }

    private var filteredApps: [SavedApplication] {
        catalog.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelPageHeader(title: "Choose apps", detail: "\(store.protectedApps.count) selected", back: done)

            HStack(spacing: PanelLayout.headerSpacing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                TextField("Search", text: $query)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
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
                RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
                    .strokeBorder(isSearchFocused ? palette.accent.opacity(0.65) : palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, PanelLayout.inset)
            .padding(.vertical, PanelLayout.sectionSpacing)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: PanelLayout.rowSpacing) {
                        ForEach(filteredApps) { app in
                            let selected = store.protectedApps.contains { $0.id == app.id }
                            Button {
                                if selected {
                                    store.removeProtection(app)
                                } else if let path = app.path {
                                    store.addProtectedApplication(at: URL(fileURLWithPath: path))
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    AppGlyph(image: app.icon)
                                    Text(app.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    RowAction(
                                        symbol: selected ? "checkmark" : "plus",
                                        tint: selected ? palette.accent : palette.secondaryText,
                                        filled: selected
                                    )
                                }
                                .padding(.horizontal, PanelLayout.rowInset)
                                .frame(height: PanelLayout.rowHeight)
                                .background(PanelSurface(tint: selected ? palette.accent : palette.surface))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(AppRowStyle(tint: palette.accent)).disabledWithReason(store.cleaningDisabledReason)
                        }
                        if filteredApps.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass").font(.system(size: 21, weight: .light))
                                Text("No results").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        }
                    }
                    .padding(.horizontal, PanelLayout.inset).padding(.bottom, PanelLayout.inset)
                }
            }
        }
        .background(PanelBackground())
        .onExitCommand(perform: done)
        .task {
            let discovered = await Task.detached(priority: .userInitiated) { AppCatalog.discover() }.value
            var byID = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for app in store.protectedApps where byID[app.id] == nil { byID[app.id] = app }
            for app in store.applications where byID[app.id] == nil {
                byID[app.id] = SavedApplication(id: app.id, name: app.name, bundleIdentifier: app.bundleIdentifier, path: app.url?.path)
            }
            catalog = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            isLoading = false
        }
    }
}
