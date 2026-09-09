import XCTest
@testable import SonosKit

/// Which TuneIn guide ids route through RadioTime's resolver rather than
/// the speaker's own `sid=254` stream form.
final class TuneInResolveRuleTests: XCTestCase {

    func testTopicsProgramsAndGroupsAlwaysResolve() {
        for id in ["t123", "p456", "g789"] {
            XCTAssertTrue(ServiceSearchProvider.tuneInNeedsResolve(id, catalogLoaded: false, tuneInListed: false), id)
            XCTAssertTrue(ServiceSearchProvider.tuneInNeedsResolve(id, catalogLoaded: true, tuneInListed: true), id)
        }
    }

    /// An unloaded catalog says nothing about the household; stations keep
    /// the legacy form.
    func testStationsKeepLegacyFormWhileCatalogIsUnloaded() {
        XCTAssertFalse(ServiceSearchProvider.tuneInNeedsResolve("s24939", catalogLoaded: false, tuneInListed: false))
    }

    func testStationsKeepLegacyFormWhenTuneInIsListed() {
        XCTAssertFalse(ServiceSearchProvider.tuneInNeedsResolve("s24939", catalogLoaded: true, tuneInListed: true))
    }

    func testStationsResolveWhenTheHouseholdHasNoTuneIn() {
        XCTAssertTrue(ServiceSearchProvider.tuneInNeedsResolve("s24939", catalogLoaded: true, tuneInListed: false))
    }

    func testEmptyIdNeverResolves() {
        XCTAssertFalse(ServiceSearchProvider.tuneInNeedsResolve("", catalogLoaded: true, tuneInListed: false))
    }
}
