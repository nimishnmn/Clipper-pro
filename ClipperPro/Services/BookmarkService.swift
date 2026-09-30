import Foundation
import AppKit

/// Manages security-scoped bookmarks so the app can re-access sandboxed files across launches.
final class BookmarkService {
    private static let defaults = UserDefaults.standard
    private static let bookmarkKey = "videoFileBookmarks"
    
    static func save(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = defaults.dictionary(forKey: bookmarkKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = data
            defaults.set(bookmarks, forKey: bookmarkKey)
        } catch {
            print("[BookmarkService] Failed to save bookmark: \(error)")
        }
    }
    
    static func resolve(url: URL) -> URL? {
        guard let bookmarks = defaults.dictionary(forKey: bookmarkKey) as? [String: Data],
              let data = bookmarks[url.path] else { return nil }
        
        var isStale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                save(url: resolved)  // refresh
            }
            return resolved
        } catch {
            print("[BookmarkService] Failed to resolve bookmark: \(error)")
            return nil
        }
    }
}
