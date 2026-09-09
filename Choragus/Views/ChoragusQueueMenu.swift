/// ChoragusQueueMenu.swift — Choragus saved queues as folder submenus.
///
/// Every menu that lists Choragus playlists (Add to Choragus Queue in the
/// browse, queue and Plex context menus; the queue panel's load menu)
/// renders the same `SavedQueueTree`: a "Choragus" submenu for playlists
/// in no folder, then one submenu per folder, nested as the folders are.
/// The caller supplies the leaf — a plain button for add-to targets, a
/// Replace / Append submenu for loading — so the folder structure lives
/// in one place.
import SwiftUI
import SonosKit

struct ChoragusQueueTreeMenu<Leaf: View>: View {
    let tree: SavedQueueTree
    @ViewBuilder let leaf: (LocalSavedQueue) -> Leaf

    var body: some View {
        // Playlists in no folder sit under a "Choragus" group, the same
        // top-level entry the Queue Library sidebar uses.
        if !tree.queues.isEmpty {
            Menu {
                ForEach(tree.queues) { leaf($0) }
            } label: {
                Label("Choragus", systemImage: "internaldrive.fill")
            }
        }
        ForEach(tree.folders) { node in
            ChoragusQueueFolderMenu(node: node, leaf: leaf)
        }
    }
}

private struct ChoragusQueueFolderMenu<Leaf: View>: View {
    let node: SavedQueueTree.Node
    let leaf: (LocalSavedQueue) -> Leaf

    var body: some View {
        Menu {
            if node.queues.isEmpty && node.folders.isEmpty {
                Text(L10n.emptyFolder)
            }
            ForEach(node.queues) { leaf($0) }
            if !node.queues.isEmpty && !node.folders.isEmpty {
                Divider()
            }
            ForEach(node.folders) { child in
                ChoragusQueueFolderMenu(node: child, leaf: leaf)
            }
        } label: {
            Label(node.folder.name, systemImage: "folder")
        }
    }
}

/// Submenu for adding an album / track to a Choragus saved queue from any
/// context menu: New Queue, then the folder tree. Pass the manager
/// explicitly — SwiftUI context menus don't reliably inherit the environment.
struct AddToChoragusQueueMenu: View {
    let item: BrowseItem
    let manager: SonosManager

    var body: some View {
        Menu {
            Button(L10n.newQueueEllipsis) {
                let name = item.title.isEmpty ? L10n.newQueue : item.title
                Task { _ = await manager.createChoragusQueue(item: item, name: name) }
            }
            let tree = manager.savedQueueTree()
            if !tree.queues.isEmpty || !tree.folders.isEmpty {
                Divider()
                ChoragusQueueTreeMenu(tree: tree) { q in
                    Button(q.name) { Task { _ = await manager.addToChoragusQueue(item: item, queueID: q.id) } }
                }
            }
        } label: {
            Label(L10n.addToChoragusQueue, systemImage: "internaldrive.fill")
        }
    }
}
