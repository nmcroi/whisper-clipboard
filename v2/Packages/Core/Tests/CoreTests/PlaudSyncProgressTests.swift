import Testing
@testable import Core

@Suite struct PlaudSyncProgressTests {
    @Test func voortgangBewaartToestandEnGeenVertaaldeResultaattekst() {
        let state = PlaudSyncProgress.downloading(current: 2, total: 5)

        #expect(state.localizationKey == "Opname %1$lld van %2$lld downloaden…")
        #expect(state.integerArguments == [2, 5])
        #expect(!state.isFailure)
    }

    @Test func enkelvoudEnMeervoudGebruikenAfzonderlijkeCatalogussleutels() {
        #expect(PlaudSyncProgress.imported(1).localizationKey == "1 nieuwe PLAUD-opname toegevoegd")
        #expect(PlaudSyncProgress.imported(3).localizationKey == "%lld nieuwe PLAUD-opnamen toegevoegd")
        #expect(PlaudSyncProgress.imported(3).integerArguments == [3])
    }

    @Test func foutBewaartAlleenSemantiekEnServerdetail() {
        let state = PlaudSyncProgress.failure(.authenticationFailed("expired"))

        #expect(state.isFailure)
        #expect(state.localizationKey == "Inloggen bij PLAUD mislukte: %@")
        #expect(PlaudSyncFailure.authenticationFailed("expired").detail == "expired")
    }
}
