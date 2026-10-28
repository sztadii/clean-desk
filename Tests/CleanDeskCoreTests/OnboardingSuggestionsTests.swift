import XCTest
@testable import CleanDeskCore

final class OnboardingSuggestionsTests: XCTestCase {
    private let policy = ApplicationPolicy(ownProcessIdentifier: 100, ownBundleIdentifier: "pl.local.cleandesk")
    private let safari = OnboardingApplication(name: "Safari", bundleIdentifier: "com.apple.Safari", path: "/Applications/Safari.app")
    private let notes = OnboardingApplication(name: "Notes", bundleIdentifier: "com.apple.Notes", path: "/System/Applications/Notes.app")

    private func running(_ app: OnboardingApplication, pid: Int32 = 200, regular: Bool = true) -> RunningApplicationRecord {
        RunningApplicationRecord(processIdentifier: pid, bundleIdentifier: app.bundleIdentifier, path: app.path, isRegular: regular, launchDate: nil)
    }

    func testTwoRunningAppsAreChosenInStableNameOrderInsteadOfFallbacks() {
        let apps = ["Zebra", "Alpha", "Beta"].map {
            OnboardingApplication(name: $0, bundleIdentifier: "test.\($0)", path: "/Applications/\($0).app")
        }
        let records = apps.map { running($0) }
        let result = OnboardingSuggestions.select(running: records, available: [safari, notes] + apps, policy: policy)
        XCTAssertEqual(result.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(result, OnboardingSuggestions.select(running: records.reversed(), available: (apps + [safari, notes]).reversed(), policy: policy))
    }

    func testFinderOwnAppAndBackgroundHelpersDoNotConsumeSuggestionSlots() {
        let finder = OnboardingApplication(name: "A Finder", bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app")
        let own = OnboardingApplication(name: "B Clean Desk", bundleIdentifier: "pl.local.cleandesk", path: "/Applications/Clean Desk.app")
        let helper = OnboardingApplication(name: "C Helper", bundleIdentifier: "test.helper", path: "/Applications/Helper.app")
        let result = OnboardingSuggestions.select(
            running: [running(finder), running(own, pid: 100), running(helper, regular: false)],
            available: [finder, own, helper, safari, notes], policy: policy
        )
        XCTAssertEqual(result, [safari, notes])
    }

    func testMultipleProcessesAndInstalledCopiesOfOneAppCountOnlyOnce() {
        let otherSafari = OnboardingApplication(name: "Safari", bundleIdentifier: "com.apple.safari", path: "/Another/Safari.app")
        let result = OnboardingSuggestions.select(
            running: [running(safari), running(safari, pid: 201)],
            available: [safari, otherSafari, notes], policy: policy
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.compactMap(\.key)), Set([safari.key!, notes.key!]))
    }

    func testSingleRunningAppUsesSafariForTheRemainingPlace() {
        let editor = OnboardingApplication(name: "Editor", bundleIdentifier: "test.editor", path: "/Applications/Editor.app")
        XCTAssertEqual(
            OnboardingSuggestions.select(running: [running(editor)], available: [notes, safari, editor], policy: policy),
            [editor, safari]
        )
    }

    func testRunningSafariUsesNotesWithoutDuplicateSafari() {
        XCTAssertEqual(
            OnboardingSuggestions.select(running: [running(safari)], available: [notes, safari], policy: policy),
            [safari, notes]
        )
    }

    func testMissingFallbacksProduceOnlyInstalledSuggestionsOrAnEmptyList() {
        XCTAssertEqual(OnboardingSuggestions.select(running: [], available: [notes], policy: policy), [notes])
        XCTAssertEqual(OnboardingSuggestions.select(running: [], available: [], policy: policy), [])
        let webstorm = OnboardingApplication(name: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm", path: "/Applications/WebStorm.app")
        XCTAssertEqual(OnboardingSuggestions.select(running: [], available: [webstorm], policy: policy), [])
    }

    func testRunningAppsWithoutLaunchableBundlesAreNotSuggested() {
        let cli = OnboardingApplication(name: "CLI", bundleIdentifier: "test.cli", path: "/usr/local/bin/cli")
        let missing = OnboardingApplication(name: "Missing", bundleIdentifier: "test.missing", path: "/Applications/Missing.app")
        XCTAssertEqual(
            OnboardingSuggestions.select(running: [running(cli), running(missing)], available: [cli, notes], policy: policy),
            [notes]
        )
    }
}
