import Foundation
import MpTracker

// No XCTest dependency: usable with macOS Command Line Tools, which do not include XCTest/iOS SDKs.
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func expectTrue(_ actual: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(actual, "Expected true", file: file, line: line)
}
func expectNil(_ actual: Any?, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == nil, "Expected nil, got \(String(describing: actual))", file: file, line: line)
}
func expectNoThrow<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try operation() } catch { preconditionFailure("Unexpected error: \(error)", file: file, line: line) }
}
func expectThrows<T>(_ operation: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line, inspect: (Error) -> Void = { _ in }) {
    do { _ = try operation() } catch { inspect(error); return }
    preconditionFailure("Expected an error", file: file, line: line)
}

@main struct ClientContractRunner {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--unsupported-mode" {
            _ = MpClient(apiBase: "https://mp-client.invalid", appCode: "invalid-mode", guestRestoreMode: CommandLine.arguments[2])
            return
        }
        let tests = MpClientGuestRestoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("automatic new guest and restored session", tests.testAutomaticInitializationCreatesGuestAndRestoresExistingSession),
            ("startup and explicit guest coalesce registration", tests.testExplicitInitializationAndGuestLoginShareRegistration),
            ("deleted session creates fresh guest without replay", tests.testDeletedSessionRecoversFreshGuestAndDoesNotReplayMutations),
            ("blocked and expired sessions never auto register", tests.testBlockedAndExpiredSessionsNeverAutoRegister),
            ("handoff explicit consent and lost ACK restart", tests.testHandoffRequiresConsentAndRestartsAfterLostAckResponse),
            ("collection reads current session without persisting credential in events", tests.testCollectionCredentialReadsCurrentSessionAndNeverBecomesRuntimeData),
            ("default compatibility/proof override", tests.testDefaultOmitsCallerSuppliedModeAndRetainsOldResolutionRules),
            ("request negotiation/same-user logout/callbacks", tests.testOptInNegotiatesGuestAccountAndLogoutAndRefreshesSameUser),
            ("reauthentication/token/configuration", tests.testReauthenticationAcceptsOnlyOptedInFalseSwitchAndClearsRuntimeContext),
            ("missing/mismatched negotiation echo", tests.testMissingOrMismatchedEchoRejectsNewTokenAndKeepsCurrentSession),
            ("old server logout response", tests.testChangeAccountAlsoRejectsOldServerBeforeReplacingToken),
            ("new action opt-in/switch validation", tests.testNewActionDisabledAndInvalidSwitchDoesNotChangeToken),
            ("sensitive 40307 preserves guest token", tests.testSensitive40307KeepsValidRestrictedGuestToken),
            ("reentrant session callback discards stale resolution", tests.testReentrantSessionChangeDiscardsResolutionWithoutOverwritingNewerToken),
            ("configuration failure permits refresh retry", tests.testConfigurationFailurePreservesReauthenticatedTokenForRefreshRetry),
            ("guest login rejects old server token", tests.testGuestLoginRejectsMissingEchoWithoutAcceptingUnsupportedToken),
            ("legacy guest login/logout compatibility", tests.testDefaultGuestLoginAndLogoutAcceptLegacyServerResponses),
            ("account read carries configured mode", tests.testAccountReadAlsoCarriesConfiguredMode),
            ("unsupported initialization modes rejected", tests.testUnsupportedInitializationModesAreRejected),
            ("reauthentication rejects nonboolean switch", tests.testReauthenticationRejectsNonBooleanAccountSwitchWithoutChangingToken),
            ("legacy resolution switch rules retained", tests.testLegacyResolutionRejectsIncorrectSwitchInBothModes),
            ("opt-in guest failure preserves memory/storage/context/callbacks", tests.testOptedInGuestLoginFailurePreservesMemoryStorageContextAndCallbacks),
            ("default guest failure retains legacy clearing", tests.testDefaultGuestLoginFailureKeepsLegacySessionClearing)
        ]
        for (name, run) in cases {
            tests.setUp(); defer { tests.tearDown() }
            try run(); print("PASS: \(name)")
        }
        print("\(cases.count) MpClient contract tests passed (platform storage/identity stand-ins).")
    }
}
