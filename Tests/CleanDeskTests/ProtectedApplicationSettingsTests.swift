import CleanDeskCore
import XCTest
@testable import CleanDesk

final class ProtectedApplicationSettingsTests: XCTestCase {
    private let key = "protectedApplications.v1"

    private func withDefaults(_ body: (UserDefaults, ProtectedApplicationSettings) throws -> Void) rethrows {
        let suite = "CleanDeskTests.ProtectedSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, ProtectedApplicationSettings(defaults: defaults))
    }

    private func app(
        id: String = "bundle:test.example",
        bundleIdentifier: String? = "test.example",
        path: String? = "/Missing/Example.app"
    ) -> SavedApplication {
        SavedApplication(id: id, name: "Example", bundleIdentifier: bundleIdentifier, path: path)
    }

    func testMissingSelectionDoesNotBecomeAnExplicitEmptyChoice() {
        withDefaults { defaults, settings in
            guard case .missing = settings.load() else { return XCTFail("Expected a missing selection") }
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func testExplicitEmptySelectionIsValid() throws {
        try withDefaults { defaults, settings in
            try settings.save([])
            guard case .valid(let apps) = settings.load() else { return XCTFail("Expected a valid empty selection") }
            XCTAssertTrue(apps.isEmpty)
            XCTAssertNotNil(defaults.data(forKey: key))
        }
    }

    func testMalformedJSONIsInvalidAndKeptForRecovery() {
        withDefaults { defaults, settings in
            let original = Data("[{\"id\":".utf8)
            defaults.set(original, forKey: key)
            guard case .invalid = settings.load() else { return XCTFail("Expected an invalid selection") }
            XCTAssertEqual(defaults.data(forKey: key), original)
        }
    }

    func testWrongDefaultsTypeIsInvalidAndKeptForRecovery() {
        withDefaults { defaults, settings in
            defaults.set("[]", forKey: key)
            guard case .invalid = settings.load() else { return XCTFail("Expected an invalid selection") }
            XCTAssertEqual(defaults.string(forKey: key), "[]")
        }
    }

    func testWrongJSONShapeAndIncompleteEntriesAreInvalid() {
        withDefaults { defaults, settings in
            for json in ["{}", "null", "[{}]", "[\"test.example\"]"] {
                let original = Data(json.utf8)
                defaults.set(original, forKey: key)
                guard case .invalid = settings.load() else { return XCTFail("Accepted invalid JSON: \(json)") }
                XCTAssertEqual(defaults.data(forKey: key), original)
            }
        }
    }

    func testIdentityMismatchInvalidatesTheWholeSelection() throws {
        try withDefaults { defaults, settings in
            let original = try JSONEncoder().encode([app(), app(id: "bundle:test.other")])
            defaults.set(original, forKey: key)
            guard case .invalid = settings.load() else { return XCTFail("Expected the entire selection to be invalid") }
            XCTAssertEqual(defaults.data(forKey: key), original)
        }
    }

    func testDuplicateIdentitiesAreInvalid() throws {
        try withDefaults { defaults, settings in
            defaults.set(try JSONEncoder().encode([app(), app()]), forKey: key)
            guard case .invalid = settings.load() else { return XCTFail("Expected duplicate identities to be invalid") }
        }
    }

    func testMissingOrUnusableIdentityIsInvalid() throws {
        try withDefaults { defaults, settings in
            let invalidApps = [
                app(id: "", bundleIdentifier: nil, path: nil),
                app(id: "bundle:test.example", bundleIdentifier: " test.example", path: nil),
                app(id: "bundle:test/example", bundleIdentifier: "test/example", path: nil),
                app(id: "bundle:test.example", path: "Example.app"),
                app(id: "bundle:test.example", path: "/Missing/Example.txt"),
            ]
            for invalid in invalidApps {
                defaults.set(try JSONEncoder().encode([invalid]), forKey: key)
                guard case .invalid = settings.load() else { return XCTFail("Accepted unusable identity: \(invalid.id)") }
            }
        }
    }

    func testValidSelectionRoundTripsWithoutRequiringInstallation() throws {
        try withDefaults { _, settings in
            let identifierOnly = app(path: nil)
            let missingPath = "/Missing/PathOnly.app"
            let pathOnly = app(
                id: try XCTUnwrap(ApplicationIdentity.key(bundleIdentifier: nil, path: missingPath)),
                bundleIdentifier: nil,
                path: missingPath
            )
            try settings.save([identifierOnly, pathOnly])
            guard case .valid(let saved) = settings.load() else { return XCTFail("Expected a valid selection") }
            XCTAssertEqual(saved.map(\.id), [identifierOnly.id, pathOnly.id])
            XCTAssertEqual(saved.map(\.path), [nil, missingPath])
            XCTAssertEqual(saved.map(\.name), ["Example", "Example"])
        }
    }

    func testInvalidSavePreservesPreviousSelection() throws {
        try withDefaults { defaults, settings in
            try settings.save([app()])
            let original = defaults.data(forKey: key)
            XCTAssertThrowsError(try settings.save([app(id: "bundle:test.other")]))
            XCTAssertEqual(defaults.data(forKey: key), original)
        }
    }

    func testExplicitSaveReplacesInvalidData() throws {
        try withDefaults { defaults, settings in
            defaults.set(Data("broken".utf8), forKey: key)
            try settings.save([app()])
            guard case .valid(let saved) = settings.load() else { return XCTFail("Expected recovery after saving a new choice") }
            XCTAssertEqual(saved.map(\.id), [app().id])
        }
    }
}
