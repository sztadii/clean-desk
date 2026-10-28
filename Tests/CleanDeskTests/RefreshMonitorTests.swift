import Foundation
import XCTest
@testable import CleanDesk

final class RefreshMonitorTests: XCTestCase {
    private final class ScheduledRefresh {
        let interval: TimeInterval
        let repeating: Bool
        let action: @MainActor () -> Void
        var isCancelled = false

        init(interval: TimeInterval, repeating: Bool, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.repeating = repeating
            self.action = action
        }

        @MainActor func fireEvenIfCancelled() { action() }
    }

    private final class Scheduler: RefreshScheduling {
        var scheduled: [ScheduledRefresh] = []

        func schedule(after interval: TimeInterval, repeating: Bool,
                      action: @escaping @MainActor () -> Void) -> RefreshCancellation {
            let event = ScheduledRefresh(interval: interval, repeating: repeating, action: action)
            scheduled.append(event)
            return RefreshCancellation { event.isCancelled = true }
        }
    }

    @MainActor
    func testHiddenApplicationEventsDoNotScheduleWorkAndOpeningRefreshesImmediately() async {
        let scheduler = Scheduler()
        var refreshes = 0
        let monitor = RefreshMonitor(onRefresh: { refreshes += 1 }, scheduler: scheduler)

        for _ in 0..<10 { monitor.applicationStateChanged() }
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(scheduler.scheduled.isEmpty)
        XCTAssertTrue(monitor.isDirty)

        monitor.setVisible(true)
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(monitor.isDirty)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertTrue(scheduler.scheduled[0].repeating)
        XCTAssertEqual(scheduler.scheduled[0].interval, 2)
    }

    @MainActor
    func testVisibleApplicationEventsAreCoalesced() async {
        let scheduler = Scheduler()
        var refreshes = 0
        let monitor = RefreshMonitor(onRefresh: { refreshes += 1 }, scheduler: scheduler)
        monitor.setVisible(true)

        for _ in 0..<10 { monitor.applicationStateChanged() }
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(monitor.isDirty)
        XCTAssertEqual(scheduler.scheduled.count, 2)
        XCTAssertFalse(scheduler.scheduled[1].repeating)
        scheduler.scheduled[1].fireEvenIfCancelled()
        XCTAssertEqual(refreshes, 2)
        XCTAssertFalse(monitor.isDirty)

        // A duplicate delivery of the same queued callback cannot refresh twice.
        scheduler.scheduled[1].fireEvenIfCancelled()
        XCTAssertEqual(refreshes, 2)
    }

    @MainActor
    func testHidingCancelsPollingAndPendingEventsIncludingAlreadyQueuedCallbacks() async {
        let scheduler = Scheduler()
        var refreshes = 0
        let monitor = RefreshMonitor(onRefresh: { refreshes += 1 }, scheduler: scheduler)
        monitor.setVisible(true)
        monitor.applicationStateChanged()
        monitor.setVisible(false)

        XCTAssertTrue(scheduler.scheduled.allSatisfy(\.isCancelled))
        for event in scheduler.scheduled { event.fireEvenIfCancelled() }
        monitor.applicationStateChanged()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(scheduler.scheduled.count, 2)
        XCTAssertTrue(monitor.isDirty)
    }

    @MainActor
    func testReopeningDoesNotReviveOldCallbacksOrCreateDuplicateTimers() async {
        let scheduler = Scheduler()
        var refreshes = 0
        let monitor = RefreshMonitor(onRefresh: { refreshes += 1 }, scheduler: scheduler)
        monitor.setVisible(true)
        monitor.setVisible(true)
        monitor.applicationStateChanged()
        let oldEvents = scheduler.scheduled
        monitor.setVisible(false)
        monitor.setVisible(true)
        monitor.setVisible(true)

        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(scheduler.scheduled.count, 3)
        for event in oldEvents { event.fireEvenIfCancelled() }
        XCTAssertEqual(refreshes, 2)
        scheduler.scheduled[2].fireEvenIfCancelled()
        XCTAssertEqual(refreshes, 3)
    }

    @MainActor
    func testPollingAbsorbsPendingNotificationRefresh() async {
        let scheduler = Scheduler()
        var refreshes = 0
        let monitor = RefreshMonitor(onRefresh: { refreshes += 1 }, scheduler: scheduler)
        monitor.setVisible(true)
        monitor.applicationStateChanged()

        scheduler.scheduled[0].fireEvenIfCancelled()
        XCTAssertEqual(refreshes, 2)
        XCTAssertTrue(scheduler.scheduled[1].isCancelled)
        scheduler.scheduled[1].fireEvenIfCancelled()
        XCTAssertEqual(refreshes, 2)
    }

    @MainActor
    func testReleasingMonitorCancelsAllWorkWithoutRetainingIt() async {
        let scheduler = Scheduler()
        var refreshes = 0
        var monitor: RefreshMonitor? = RefreshMonitor(onRefresh: { refreshes += 1 }, scheduler: scheduler)
        weak var weakMonitor: RefreshMonitor?
        weakMonitor = monitor
        monitor?.setVisible(true)
        monitor?.applicationStateChanged()

        monitor = nil
        XCTAssertNil(weakMonitor)
        XCTAssertTrue(scheduler.scheduled.allSatisfy(\.isCancelled))
        for event in scheduler.scheduled { event.fireEvenIfCancelled() }
        XCTAssertEqual(refreshes, 1)
    }

    @MainActor
    func testRefreshMayCloseThePanelWithoutLeavingATimerRunning() async {
        let scheduler = Scheduler()
        let owner = MonitorOwner()
        let monitor = RefreshMonitor(onRefresh: { owner.monitor?.setVisible(false) }, scheduler: scheduler)
        owner.monitor = monitor

        monitor.setVisible(true)
        XCTAssertFalse(monitor.isVisible)
        XCTAssertTrue(scheduler.scheduled.allSatisfy(\.isCancelled))
    }

    private final class MonitorOwner {
        weak var monitor: RefreshMonitor?
    }
}
