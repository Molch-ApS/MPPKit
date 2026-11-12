import XCTest
@testable import MPPModel

/// How much a resource is booked: the peak is the highest load at one time,
/// held against Max Units, and the tasks under way then are the ones marked.
final class ResourceLoadTests: XCTestCase {
    private func d(_ day: Int, _ h: Int = 8) -> Date { MPPTime.date(2026, 11, day, h, 0) }

    /// Tasks as (uid, start day, finish day, units), all for resource 1.
    private func plan(maxUnits: Double, _ tasks: [(Int, Int, Int, Double)]) -> Project {
        var p = Project(title: "Load", start: d(2))
        var r = Resource(uid: 1, name: "Crew")
        r.maxUnits = maxUnits
        p.resources = [r, Resource(uid: 2, name: "Idle")]
        p.tasks = tasks.map { ProjectTask(uid: $0.0, name: "Task \($0.0)", start: d($0.1), finish: d($0.2, 17)) }
        p.assignments = tasks.map { Assignment(taskUID: $0.0, resourceUID: 1, units: $0.3) }
        return p
    }

    func testOneTaskAboveMaxUnitsIsOverAllocated() {
        // 300% for three days of a week: the week's average is under 200%, the days are not.
        let p = plan(maxUnits: 2, [(1, 2, 4, 3)])
        let crew = p.resources[0]
        XCTAssertEqual(p.peakLoad(of: crew), 3, accuracy: 0.0001)
        XCTAssertLessThan(p.weeklyLoad(of: crew).max() ?? 0, 2)
        XCTAssertTrue(p.isOverAllocated(crew))
        XCTAssertEqual(p.overAllocatedTasks(), [1])
        XCTAssertEqual(p.allocationSummary().over, 1)
        XCTAssertEqual(p.allocationSummary().peak, 1.5, accuracy: 0.0001)
    }

    func testTasksThatOverlapAddUp() {
        // 1 and 2 share Wednesday; 3 comes after both.
        let p = plan(maxUnits: 1, [(1, 2, 4, 0.6), (2, 4, 6, 0.6), (3, 9, 10, 1)])
        let crew = p.resources[0]
        XCTAssertEqual(p.peakLoad(of: crew), 1.2, accuracy: 0.0001)
        XCTAssertEqual(p.overAllocatedTasks(of: crew), [1, 2])
        XCTAssertFalse(p.isOverAllocated(p.resources[1]))
        XCTAssertEqual(p.peakLoad(of: p.resources[1]), 0)
    }

    func testTasksThatMeetDoNotOverlap() {
        var p = plan(maxUnits: 1, [(1, 2, 3, 1), (2, 3, 4, 1)])
        p.tasks[0].finish = d(3, 12)
        p.tasks[1].start = d(3, 12)
        XCTAssertEqual(p.peakLoad(of: p.resources[0]), 1, accuracy: 0.0001)
        XCTAssertFalse(p.isOverAllocated(p.resources[0]))
        XCTAssertTrue(p.overAllocatedTasks().isEmpty)
    }

    func testAMilestoneCarriesNoLoad() {
        var p = plan(maxUnits: 1, [(1, 2, 4, 1), (2, 3, 3, 1)])
        p.tasks[1].finish = p.tasks[1].start
        XCTAssertEqual(p.peakLoad(of: p.resources[0]), 1, accuracy: 0.0001)
        XCTAssertTrue(p.overAllocatedTasks().isEmpty)
    }

    func testFullButNotOver() {
        let p = plan(maxUnits: 0.5, [(1, 2, 4, 0.5), (2, 5, 6, 0.5)])
        XCTAssertFalse(p.isOverAllocated(p.resources[0]))
        XCTAssertEqual(p.allocationSummary().over, 0)
    }
}
