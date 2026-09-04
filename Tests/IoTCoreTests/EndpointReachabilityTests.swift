import Testing
@testable import IoTCore

struct EndpointReachabilityTests {

    @Test func successAndRedirectAreReachable() {
        #expect(AdaptiveLatencyProber.isReachableHTTPStatus(200))
        #expect(AdaptiveLatencyProber.isReachableHTTPStatus(301))
        #expect(AdaptiveLatencyProber.isReachableHTTPStatus(399))
    }

    @Test func unauthorizedProvesTheOriginIsAlive() {
        // An auth-enabled Frigate answers 401 to a stateless HEAD. Treating
        // that as unreachable made every secured server look down.
        #expect(AdaptiveLatencyProber.isReachableHTTPStatus(401))
    }

    @Test func methodNotAllowedProvesTheOriginIsAlive() {
        // Some proxies reject HEAD with 405 while serving real GETs fine.
        #expect(AdaptiveLatencyProber.isReachableHTTPStatus(405))
    }

    @Test func forbiddenIsNotReachable() {
        // 403 usually means a zero-trust token or header is missing or
        // rejected — the app's real requests would fail too.
        #expect(!AdaptiveLatencyProber.isReachableHTTPStatus(403))
    }

    @Test func serverErrorsAreNotReachable() {
        #expect(!AdaptiveLatencyProber.isReachableHTTPStatus(500))
        #expect(!AdaptiveLatencyProber.isReachableHTTPStatus(502))
    }
}
