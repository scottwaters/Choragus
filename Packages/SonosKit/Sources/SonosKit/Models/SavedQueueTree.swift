/// SavedQueueTree.swift — Choragus saved queues arranged by folder.
///
/// The repository stores folders (with a parent) and queue memberships
/// (many-to-many) as flat lists. Menus and pickers need the nested form:
/// folders inside folders, each holding its member queues, with the
/// queues that belong to no folder at the top level. Built once per
/// menu open from the two flat lists; pure so it is unit-tested.
import Foundation

public struct SavedQueueTree: Equatable {

    /// One folder with its subfolders and member queues, both name-sorted.
    public struct Node: Equatable, Identifiable {
        public let folder: SavedQueueFolder
        public let folders: [Node]
        public let queues: [LocalSavedQueue]
        public var id: Int64 { folder.id }
    }

    /// Top-level folders, name-sorted.
    public let folders: [Node]
    /// Queues in no folder (or whose folders no longer exist), name-sorted.
    public let queues: [LocalSavedQueue]

    public init(folders: [SavedQueueFolder], queues: [LocalSavedQueue]) {
        let folderIDs = Set(folders.map(\.id))
        let byName: (LocalSavedQueue, LocalSavedQueue) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var queuesByFolder: [Int64: [LocalSavedQueue]] = [:]
        var loose: [LocalSavedQueue] = []
        for queue in queues {
            let live = queue.folderIDs.filter(folderIDs.contains)
            if live.isEmpty {
                loose.append(queue)
            } else {
                for folderID in live { queuesByFolder[folderID, default: []].append(queue) }
            }
        }
        // A parent that no longer exists reads as top level; the ancestor
        // set stops a cyclic parent chain from recursing without end.
        func parentOf(_ folder: SavedQueueFolder) -> Int64? {
            folder.parentID.flatMap { folderIDs.contains($0) ? $0 : nil }
        }
        func build(parent: Int64?, ancestors: Set<Int64>) -> [Node] {
            folders.filter { parentOf($0) == parent && !ancestors.contains($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { folder in
                    Node(folder: folder,
                         folders: build(parent: folder.id, ancestors: ancestors.union([folder.id])),
                         queues: (queuesByFolder[folder.id] ?? []).sorted(by: byName))
                }
        }
        self.folders = build(parent: nil, ancestors: [])
        self.queues = loose.sorted(by: byName)
    }

    /// Folders in depth-first order with their nesting depth, for flat
    /// pickers that indent instead of nesting.
    public var flattenedFolders: [(folder: SavedQueueFolder, depth: Int)] {
        var out: [(folder: SavedQueueFolder, depth: Int)] = []
        func walk(_ nodes: [Node], _ depth: Int) {
            for node in nodes {
                out.append((node.folder, depth))
                walk(node.folders, depth + 1)
            }
        }
        walk(folders, 0)
        return out
    }
}
