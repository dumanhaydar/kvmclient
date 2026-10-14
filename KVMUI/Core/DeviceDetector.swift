import Foundation

/// Identifies the firmware behind an address from cheap, mostly unauthenticated endpoints.
enum DeviceDetector {
    static func detect(_ http: HTTPClient) async -> DeviceKind? {
        async let jet = JetKVMDriver.detect(http)
        async let pi = PiKVMDriver.detect(http)
        async let nano = NanoKVMDriver.detect(http)
        async let tiny = TinyPilotDriver.detect(http)
        let results: [(DeviceKind, Bool)] = await [(.jetKVM, jet), (.piKVM, pi), (.nanoKVM, nano), (.tinyPilot, tiny)]
        return results.first(where: \.1)?.0
    }
}
