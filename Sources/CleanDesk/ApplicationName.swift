import Foundation

/// Keeps application labels in English regardless of the Mac's preferred language.
/// Reads bundle files only, so it can also be used during background catalog scans.
enum ApplicationName {
    static func displayName(for url: URL?, fallback: String) -> String {
        guard let url, let bundle = Bundle(url: url) else { return fallback }

        if let resources = bundle.resourceURL {
            let localizations = (try? FileManager.default.contentsOfDirectory(
                at: resources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let englishDirectories = localizations.filter { directory in
                guard directory.pathExtension.lowercased() == "lproj" else { return false }
                let language = directory.deletingPathExtension().lastPathComponent.lowercased()
                return language == "en" || language == "english"
                    || language.hasPrefix("en-") || language.hasPrefix("en_")
            }.sorted {
                let left = englishPreference($0)
                let right = englishPreference($1)
                return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
            }

            for directory in englishDirectories {
                let stringsURL = directory.appendingPathComponent("InfoPlist.strings")
                guard let data = try? Data(contentsOf: stringsURL),
                      let dictionary = (try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil
                      )) as? [String: Any] else { continue }
                if let name = name(in: dictionary) { return name }
            }
        }

        // infoDictionary is the raw plist. localizedInfoDictionary would use the
        // user's system language and can introduce non-English app names here.
        return name(in: bundle.infoDictionary ?? [:]) ?? fallback
    }

    private static func name(in dictionary: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func englishPreference(_ directory: URL) -> Int {
        switch directory.deletingPathExtension().lastPathComponent.lowercased() {
        case "en": return 0
        case "english": return 1
        case "en-us", "en_us": return 2
        case "en-gb", "en_gb": return 3
        default: return 4
        }
    }
}
