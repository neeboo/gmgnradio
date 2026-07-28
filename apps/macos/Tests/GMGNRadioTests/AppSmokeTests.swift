import Testing
@testable import GMGNRadio

@Test
func productIdentityIsStable() {
    #expect(ProductIdentity.displayName == "gmgn radio")
    #expect(ProductIdentity.bundleIdentifier == "ai.gmgn.radio")
}
