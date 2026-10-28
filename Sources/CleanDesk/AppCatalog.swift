import Foundation
import CleanDeskCore

/// Installed applications, independently of which applications are running.
/// Discovery reads files only, so callers can run it away from the main actor.
enum AppCatalog {
    static func discover() -> [SavedApplication] {
        discover(in: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ], additionalApplications: [
            // Finder lives outside the normal Applications roots. Include only
            // its bundle, without exposing the other CoreServices utilities.
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        ])
    }

    // Keeping roots injectable makes catalog behavior testable without changing
    // installed applications. Earlier roots win when two bundles share an ID.
    static func discover(in roots: [URL], additionalApplications: [URL] = []) -> [SavedApplication] {
        var scanner = Scanner(ownBundleIdentifier: Bundle.main.bundleIdentifier)
        for root in roots {
            scanner.visitDirectory(root.resolvingSymlinksInPath(), depth: 0)
        }
        for url in additionalApplications {
            scanner.addApplication(at: url.resolvingSymlinksInPath())
        }
        return scanner.applications.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private struct Scanner {
        let ownBundleIdentifier: String?
        var applications: [String: SavedApplication] = [:]
        var visitedDirectories: Set<String> = []
        private let fileManager = FileManager.default
        private let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .isHiddenKey
        ]

        mutating func visitDirectory(_ directory: URL, depth: Int) {
            // These bounds protect against unusual directory links or very large
            // development trees inside Applications. App bundles are never walked.
            guard depth <= 8, visitedDirectories.count < 5_000,
                  visitedDirectories.insert(directory.standardizedFileURL.path).inserted,
                  let entries = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                  ) else { return }

            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard !entry.lastPathComponent.hasPrefix("."),
                      let values = try? entry.resourceValues(forKeys: resourceKeys),
                      // Safari's system symlink is marked hidden on recent macOS,
                      // even though Finder presents Safari in Applications.
                      values.isHidden != true || values.isSymbolicLink == true else { continue }
                let target: URL
                if values.isSymbolicLink == true {
                    // Some system app links (including Safari) also report
                    // isAliasFile; POSIX symlink resolution takes precedence.
                    target = entry.resolvingSymlinksInPath().standardizedFileURL
                } else if values.isAliasFile == true {
                    // Resolve Finder aliases without opening a dialog or mounting
                    // an unavailable volume. Only application aliases are followed.
                    guard let resolved = try? URL(
                        resolvingAliasFileAt: entry,
                        options: [.withoutUI, .withoutMounting]
                    ) else { continue }
                    target = resolved.resolvingSymlinksInPath().standardizedFileURL
                } else {
                    target = entry.resolvingSymlinksInPath().standardizedFileURL
                }

                if target.pathExtension.lowercased() == "app" {
                    addApplication(at: target)
                    continue
                }
                // Directory aliases/symlinks may lead outside the installation
                // roots or back to an ancestor; follow only their .app targets.
                guard values.isSymbolicLink != true, values.isAliasFile != true,
                      values.isDirectory == true, values.isPackage != true else { continue }
                visitDirectory(target, depth: depth + 1)
            }
        }

        mutating func addApplication(at url: URL) {
            let infoURL = url.appendingPathComponent("Contents/Info.plist")
            guard url.isFileURL, url.pathExtension.lowercased() == "app",
                  let data = try? Data(contentsOf: infoURL),
                  let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  !Self.enabled(info["LSBackgroundOnly"]),
                  let executable = info["CFBundleExecutable"] as? String,
                  !executable.isEmpty,
                  fileManager.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path)
            else { return }

            let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedIdentifier = bundleIdentifier?.lowercased()
            let packageType = info["CFBundlePackageType"] as? String
            // Finder uses its own package type instead of the normal APPL.
            guard info["CFBundlePackageType"] == nil || packageType == "APPL"
                    || (packageType == "FNDR" && normalizedIdentifier == "com.apple.finder"),
                  normalizedIdentifier != "pl.local.cleandesk",
                  ownBundleIdentifier == nil || normalizedIdentifier != ownBundleIdentifier?.lowercased(),
                  let key = ApplicationIdentity.key(bundleIdentifier: bundleIdentifier, path: url.path),
                  applications[key] == nil else { return }

            let name = ApplicationName.displayName(for: url, fallback: url.deletingPathExtension().lastPathComponent)
            applications[key] = SavedApplication(id: key, name: name, bundleIdentifier: bundleIdentifier, path: url.path)
        }

        private static func enabled(_ value: Any?) -> Bool {
            if let number = value as? NSNumber { return number.boolValue }
            guard let string = value as? String else { return false }
            return ["true", "yes", "1"].contains(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }

    }
}
