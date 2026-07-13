import Foundation
import Testing
@testable import Core

@Suite struct RecordingStopwatchTests {

    @Test func elapsedGroeitTijdensLopen() {
        var klok = RecordingStopwatch()
        klok.start(at: 100)
        #expect(klok.elapsed(at: 100) == 0)
        #expect(klok.elapsed(at: 105) == 5)
        #expect(klok.isRunning)
    }

    @Test func pauzeBevriestElapsed() {
        var klok = RecordingStopwatch()
        klok.start(at: 100)
        klok.pause(at: 110)
        #expect(klok.elapsed(at: 110) == 10)
        // Tijd verstrijkt, maar de klok staat stil.
        #expect(klok.elapsed(at: 500) == 10)
        #expect(!klok.isRunning)
    }

    @Test func hervattenTeltPauzegatNietMee() {
        var klok = RecordingStopwatch()
        klok.start(at: 100)
        klok.pause(at: 110)   // 10 s opgenomen
        klok.resume(at: 200)  // 90 s pauze — telt niet
        #expect(klok.elapsed(at: 205) == 15)
    }

    @Test func meerderePauzeCycliTellenCorrectOp() {
        var klok = RecordingStopwatch()
        klok.start(at: 0)
        klok.pause(at: 10)    // +10
        klok.resume(at: 50)
        klok.pause(at: 65)    // +15
        klok.resume(at: 100)
        #expect(klok.elapsed(at: 110) == 35)
    }

    @Test func dubbelPauzerenIsNoOp() {
        var klok = RecordingStopwatch()
        klok.start(at: 0)
        klok.pause(at: 10)
        klok.pause(at: 20)
        #expect(klok.elapsed(at: 30) == 10)
    }

    @Test func dubbelHervattenIsNoOp() {
        var klok = RecordingStopwatch()
        klok.start(at: 0)
        klok.pause(at: 10)
        klok.resume(at: 20)
        klok.resume(at: 30)   // no-op: mag het startpunt niet verschuiven
        #expect(klok.elapsed(at: 40) == 30)
    }

    @Test func stopTijdensPauzeGeeftBevrorenWaarde() {
        var klok = RecordingStopwatch()
        klok.start(at: 0)
        klok.pause(at: 12)
        // Stoppen terwijl gepauzeerd: de bevroren tijd is de eindtijd.
        #expect(klok.elapsed(at: 100) == 12)
        klok.stopAndReset()
        #expect(klok.elapsed(at: 200) == 0)
        #expect(!klok.isRunning)
    }

    @Test func startResetEerdereToestand() {
        var klok = RecordingStopwatch()
        klok.start(at: 0)
        klok.pause(at: 30)
        klok.start(at: 100)
        #expect(klok.elapsed(at: 105) == 5)
    }

    @Test func teruglopendeKlokKlemtOpNul() {
        var klok = RecordingStopwatch()
        klok.start(at: 100)
        // `now` vóór het startpunt (klok-skew): nooit negatief.
        #expect(klok.elapsed(at: 50) == 0)
        klok.pause(at: 90)
        #expect(klok.elapsed(at: 200) == 0)
    }
}
