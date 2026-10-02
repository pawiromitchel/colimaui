import Testing
@testable import ColimaKit

@Suite struct AppearanceModeTests {
    @Test func offersSystemLightAndDarkInThatOrder() {
        #expect(AppearanceMode.allCases == [.system, .light, .dark])
        #expect(AppearanceMode.allCases.map(\.title) == ["System", "Light", "Dark"])
    }

    @Test func eachModeHasItsOwnSymbol() {
        #expect(Set(AppearanceMode.allCases.map(\.symbol)).count == 3)
    }

    @Test func storedValuesRoundTrip() {
        for mode in AppearanceMode.allCases { #expect(AppearanceMode(stored: mode.rawValue) == mode) }
    }

    @Test func unknownOrMissingValuesFollowTheSystem() {
        #expect(AppearanceMode(stored: nil) == .system)
        #expect(AppearanceMode(stored: "") == .system)
        #expect(AppearanceMode(stored: "sepia") == .system)
    }
}
