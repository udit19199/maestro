//
//  WorkspaceBookmarkStore.swift
//  zoro
//
//  Persists security-scoped bookmarks for the optional workspace folder.
//

import Foundation

@MainActor
final class WorkspaceBookmarkStore {
    static let shared = WorkspaceBookmarkStore()

    private let defaultsKey = "workspace_security_scoped_bookmark"

    private init() {}

    func save(url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            // Bookmark may fail outside sandbox; path still works for current session.
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    func restoreIfNeeded(into workspace: WorkspaceManager) {
        guard workspace.workspaceURL == nil,
              let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                // Refresh bookmark on next attach.
                clear()
            }
            _ = url.startAccessingSecurityScopedResource()
            workspace.workspaceURL = url
            if isStale {
                save(url: url)
            }
        } catch {
            clear()
        }
    }
}
