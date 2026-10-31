/// The same actions are exposed by the dashboard and both context menus.
enum CleanupMode: CaseIterable {
    case keepFavourites
    case closeAll

    var title: String {
        switch self {
        case .keepFavourites: return "Keep favourites"
        case .closeAll: return "Close all"
        }
    }

    var symbol: String {
        switch self {
        case .keepFavourites: return "star"
        case .closeAll: return "trash"
        }
    }

    var isDestructive: Bool { self == .closeAll }
}
