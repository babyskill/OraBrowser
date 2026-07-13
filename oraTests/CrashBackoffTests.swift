import Foundation
@testable import Ora
import Testing

struct CrashBackoffTests {
    @Test func stopsReloadingAfterMoreThanThreeCrashesInTenSeconds() {
        var history = CrashHistory()
        let start = Date(timeIntervalSince1970: 1000)

        #expect(history.record(start) == 1)
        #expect(history.record(start.addingTimeInterval(1)) == 2)
        #expect(history.record(start.addingTimeInterval(2)) == 3)
        #expect(history.record(start.addingTimeInterval(3)) == 4)
    }

    @Test func dropsCrashesOutsideTheWindow() {
        var history = CrashHistory()
        let start = Date(timeIntervalSince1970: 1000)
        _ = history.record(start)

        #expect(history.record(start.addingTimeInterval(11)) == 1)
    }
}
