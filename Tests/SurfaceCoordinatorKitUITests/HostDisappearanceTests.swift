import Testing

@testable import SurfaceCoordinatorKitUI

/// The host's root view also disappears when a full-screen cover — including
/// the host's own — covers it. That is not a dismissal: a landed presentation
/// ends only when its content reports it, or a launch paywall is taken down
/// right after it landed.
struct HostDisappearanceTests {
    @Test(arguments: [true, false])
    func landedPresentationIsNeverEndedByTheHost(isSceneActive: Bool) {
        #expect(HostDisappearance.action(isSceneActive: isSceneActive, isLanded: true) == .keep)
    }

    @Test func coveredHostKeepsAnUnlandedPermit() {
        #expect(HostDisappearance.action(isSceneActive: true, isLanded: false) == .keep)
    }

    @Test func backgroundedHostGivesBackAnUnlandedPermit() {
        #expect(HostDisappearance.action(isSceneActive: false, isLanded: false) == .abandon)
    }
}
