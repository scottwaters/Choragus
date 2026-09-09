import XCTest
@testable import SonosKit

final class SavedQueueTreeTests: XCTestCase {

    private func queue(_ id: Int64, _ name: String, folders: [Int64] = []) -> LocalSavedQueue {
        LocalSavedQueue(id: id, name: name, createdAt: Date(), trackCount: 1, folderIDs: folders)
    }

    func testLooseQueuesSitAtTopLevelSortedByName() {
        let tree = SavedQueueTree(folders: [], queues: [queue(1, "zeta"), queue(2, "Alpha")])
        XCTAssertEqual(tree.queues.map(\.name), ["Alpha", "zeta"])
        XCTAssertTrue(tree.folders.isEmpty)
    }

    func testNestedFoldersCarryTheirMembers() {
        let folders = [SavedQueueFolder(id: 10, name: "Rock"),
                       SavedQueueFolder(id: 11, name: "Live", parentID: 10),
                       SavedQueueFolder(id: 12, name: "Ambient")]
        let queues = [queue(1, "Loose"), queue(2, "Rush", folders: [10]), queue(3, "Rush Live", folders: [11])]
        let tree = SavedQueueTree(folders: folders, queues: queues)
        XCTAssertEqual(tree.queues.map(\.name), ["Loose"])
        XCTAssertEqual(tree.folders.map(\.folder.name), ["Ambient", "Rock"])
        let rock = tree.folders[1]
        XCTAssertEqual(rock.queues.map(\.name), ["Rush"])
        XCTAssertEqual(rock.folders.map(\.folder.name), ["Live"])
        XCTAssertEqual(rock.folders[0].queues.map(\.name), ["Rush Live"])
    }

    func testQueueInSeveralFoldersAppearsInEach() {
        let folders = [SavedQueueFolder(id: 10, name: "A"), SavedQueueFolder(id: 11, name: "B")]
        let tree = SavedQueueTree(folders: folders, queues: [queue(1, "Both", folders: [10, 11])])
        XCTAssertEqual(tree.folders[0].queues.map(\.id), [1])
        XCTAssertEqual(tree.folders[1].queues.map(\.id), [1])
        XCTAssertTrue(tree.queues.isEmpty)
    }

    func testMembershipOfDeletedFolderFallsBackToTopLevel() {
        let tree = SavedQueueTree(folders: [], queues: [queue(1, "Orphan", folders: [99])])
        XCTAssertEqual(tree.queues.map(\.name), ["Orphan"])
    }

    func testFlattenedFoldersAreDepthFirstWithDepth() {
        let folders = [SavedQueueFolder(id: 10, name: "Rock"),
                       SavedQueueFolder(id: 11, name: "Live", parentID: 10),
                       SavedQueueFolder(id: 12, name: "Ambient")]
        let flat = SavedQueueTree(folders: folders, queues: []).flattenedFolders
        XCTAssertEqual(flat.map { "\($0.depth):\($0.folder.name)" }, ["0:Ambient", "0:Rock", "1:Live"])
    }

    func testMissingParentFallsToTopLevelAndCyclesTerminate() {
        let orphan = SavedQueueTree(folders: [SavedQueueFolder(id: 5, name: "Lost", parentID: 99)], queues: [])
        XCTAssertEqual(orphan.folders.map(\.folder.id), [5])
        let cyclic = SavedQueueTree(folders: [SavedQueueFolder(id: 1, name: "A", parentID: 2),
                                              SavedQueueFolder(id: 2, name: "B", parentID: 1)], queues: [])
        XCTAssertTrue(cyclic.folders.isEmpty)
        XCTAssertTrue(cyclic.flattenedFolders.isEmpty)
    }
}
