import Foundation
import MachO
import MpTracker

private final class ClientContractProtocol: URLProtocol {
    static var handle: ((URLRequest, [String: Any]) -> (Int, [String: Any]))!
    static var transportError: Error?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mp-client.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let error = Self.transportError { client?.urlProtocol(self, didFailWithError: error); return }
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(buffer, count: count)
            }
            data = body
        } else { data = Data("{}".utf8) }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let (status, value) = Self.handle(request, body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MpClientGuestRestoreTests {
    private let mode = "same_user_restricted"
    private var client: MpClient!
    private var appCode: String!
    func testHandoffRequiresConsentAndRestartsAfterLostAckResponse() throws {
        client=makeClient(optedIn:false);client.setSession("web-old-app-session")
        var phase="approved",redeems=0,loseAck=true
        ClientContractProtocol.handle = { request,body in
            let path=request.url!.path
            if path.hasSuffix("/claim") {expectNil(body["verifier"]);expectTrue((body["challenge"] as? String)?.count == 64);return self.success(["claimId":body["claimId"] ?? "","status":"pending"])}
            if path.hasSuffix("/status") {return self.success(["status":phase])}
            if path.hasSuffix("/redeem") {redeems += 1;phase="delivered";return self.success(["accessToken":"handoff-new","userId":"web-user"])}
            if path.hasSuffix("/current") {expectEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer handoff-new");return self.success(["userId":"web-user"])}
            if path.hasSuffix("/ack") {phase="acknowledged";if loseAck {loseAck=false;return (500,["code":50301,"message":"lost ack"])};return self.success(["status":phase])}
            preconditionFailure("Unexpected handoff request")
        }
        _ = try awaitResult {client.beginAppHandoff(String(repeating:"h",count:43),completion:$0)}.get()
        expectThrows(try awaitResult {client.completeAppHandoff(switchConfirmed:false,completion:$0)}.get())
        expectThrows(try awaitResult {client.completeAppHandoff(switchConfirmed:true,completion:$0)}.get())
        client=makeClient(optedIn:false)
        _ = try awaitResult {client.completeAppHandoff(switchConfirmed:true,completion:$0)}.get()
        expectEqual(redeems,1);expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String,"web-user")
    }
    func testCollectionCredentialReadsCurrentSessionAndNeverBecomesRuntimeData() {
        client = makeClient(optedIn: false)
        client.setSession("first")
        expectEqual(MpTracker.shared.collectionAccessToken(), "first")
        client.setSession("second")
        expectEqual(MpTracker.shared.collectionAccessToken(), "second")
        expectNil(MpTracker.shared.runtimeFields["accessToken"])
        ClientContractProtocol.handle = { request, body in
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer second")
            expectEqual((body["events"] as? [[String: Any]])?.first?["user_id"] as? String, "historical-user")
            expectTrue(!String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!.contains("second"))
            return (200, ["code": 0])
        }
        var accepted: Bool?
        MpTracker.shared.reportCollection([["user_id": "historical-user"]]) { accepted = $0 }
        let timeout = Date().addingTimeInterval(5)
        while accepted == nil && Date() < timeout { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        expectEqual(accepted, true)
        client.clearLocalSession()
        expectNil(MpTracker.shared.collectionAccessToken())
        let other = MpClient(apiBase: "https://different.invalid", appCode: appCode)
        other.setSession("private")
        expectNil(MpTracker.shared.collectionAccessToken())
        other.clearLocalSession()
    }
    func setUp() {
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        _ = URLProtocol.registerClass(ClientContractProtocol.self)
        appCode = "contract-" + UUID().uuidString
    }
    func tearDown() {
        client?.clearLocalSession()
        URLProtocol.unregisterClass(ClientContractProtocol.self)
        ClientContractProtocol.handle = nil
        ClientContractProtocol.transportError = nil
    }
    private func makeClient(optedIn: Bool = true, autoGuestLogin: Bool = false) -> MpClient {
        MpClient(apiBase: "https://mp-client.invalid", appCode: appCode, guestRestoreMode: optedIn ? mode : nil, autoGuestLogin: autoGuestLogin)
    }
    private func success(_ data: [String: Any]) -> (Int, [String: Any]) { (200, ["code": 0, "data": data]) }
    private func configuration() -> [String: Any] {
        ["user": ["userId": "1001", "account": ["accountType": "registered", "sessionType": "guest", "loginMethod": "guest"]], "configVersion": "restricted", "authenticationRequired": true]
    }
    private func awaitResult(_ operation: (@escaping (Result<[String: Any], Error>) -> Void) -> Void) -> Result<[String: Any], Error> {
        precondition(Thread.isMainThread)
        var value: Result<[String: Any], Error>!
        operation { value = $0 }
        let timeout = Date().addingTimeInterval(5)
        while value == nil && Date() < timeout { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        precondition(value != nil, "Client completion timed out")
        return value
    }
    private func assertToken(_ expected: String) {
        ClientContractProtocol.handle = { request, _ in
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + expected)
            return self.success(self.configuration())
        }
        expectNoThrow(try awaitResult { client.refresh(completion: $0) }.get())
    }

    func testDefaultOmitsCallerSuppliedModeAndRetainsOldResolutionRules() throws {
        client = makeClient(optedIn: false); client.setSession("guest")
        for (action, switched) in [("guest_upgraded", false), ("existing_account_login", true)] {
            ClientContractProtocol.handle = { request, body in
                expectNil(body["guestRestoreMode"])
                if request.url!.path.hasSuffix("login-or-bind") {
                    return self.success(["accessToken": "formal", "userId": "1001", "action": action, "accountSwitched": switched])
                }
                return self.success(self.configuration())
            }
            let result = try awaitResult { client.loginOrBindIdentity(["provider": "google", "guestRestoreMode": mode], completion: $0) }.get()
            expectEqual(result["action"] as? String, action)
        }
    }
    func testOptInNegotiatesGuestAccountAndLogoutAndRefreshesSameUser() throws {
        client = makeClient(); var changes = 0
        client.onSessionChanged = { changes += 1 }
        ClientContractProtocol.handle = { request, body in
            if request.url!.path.contains("/accounts/") || request.url!.path.hasSuffix("login/guest") {
                expectEqual(body["guestRestoreMode"] as? String, self.mode)
                expectEqual(body["appCode"] as? String, self.appCode)
                return self.success(["accessToken": request.url!.path.hasSuffix("logout") ? "restricted-guest" : "guest", "guestRestoreMode": self.mode])
            }
            return self.success(self.configuration())
        }
        _ = try awaitResult { client.loginGuest(completion: $0) }.get()
        _ = try awaitResult { client.loginIdentity(["provider": "google", "guestRestoreMode": "caller-override"], completion: $0) }.get()
        let config = try awaitResult { client.logout(completion: $0) }.get()
        expectEqual((config["user"] as? [String: Any])?["userId"] as? String, "1001")
        expectEqual(config["authenticationRequired"] as? Bool, true)
        expectEqual(changes, 3) // Opted-in guest login switches only after negotiation succeeds.
        expectTrue(client.hasSession)
        assertToken("restricted-guest")
    }
    func testReauthenticationAcceptsOnlyOptedInFalseSwitchAndClearsRuntimeContext() throws {
        client = makeClient(); client.setSession("restricted-guest")
        MpTracker.shared.runtimeFields = ["user_id": "old", "ab_snapshot": "stale", "config_version": "old"]
        var changes = 0; client.onSessionChanged = {
            changes += 1
            expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String, "")
            expectEqual(MpTracker.shared.runtimeFields["ab_snapshot"] as? String, "{}")
            expectEqual(MpTracker.shared.runtimeFields["config_version"] as? String, "")
        }
        ClientContractProtocol.handle = { request, body in
            if request.url!.path.hasSuffix("login-or-bind") {
                expectEqual(body["guestRestoreMode"] as? String, self.mode)
                return self.success(["accessToken": "reauthenticated", "userId": "1001", "guestRestoreMode": self.mode, "action": "account_reauthenticated", "accountSwitched": false])
            }
            return self.success(self.configuration())
        }
        let result = try awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }.get()
        expectEqual(result["action"] as? String, "account_reauthenticated")
        expectEqual(result["configurationRefreshRequired"] as? Bool, false)
        expectEqual(changes, 1)
        expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String, "1001")
        expectEqual(MpTracker.shared.runtimeFields["config_version"] as? String, "restricted")
        assertToken("reauthenticated")
    }
    func testMissingOrMismatchedEchoRejectsNewTokenAndKeepsCurrentSession() {
        client = makeClient(); client.setSession("valid-guest")
        for echo in [nil, "other-mode"] as [String?] {
            ClientContractProtocol.handle = { _, _ in
                var login: [String: Any] = ["accessToken": "untrusted", "userId": "1001", "action": "guest_upgraded", "accountSwitched": false]
                login["guestRestoreMode"] = echo
                return self.success(login)
            }
            let response = awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }
            expectThrows(try response.get()) { expectTrue($0.localizedDescription.contains("guestRestoreMode")) }
            assertToken("valid-guest")
        }
    }
    func testChangeAccountAlsoRejectsOldServerBeforeReplacingToken() {
        client = makeClient(); client.setSession("valid-guest")
        ClientContractProtocol.handle = { _, _ in self.success(["accessToken": "untrusted"]) }
        expectThrows(try awaitResult { client.logout(completion: $0) }.get())
        assertToken("valid-guest")
    }
    func testNewActionDisabledAndInvalidSwitchDoesNotChangeToken() {
        for optedIn in [false, true] {
            client = makeClient(optedIn: optedIn); client.setSession("valid-guest")
            ClientContractProtocol.handle = { _, _ in self.success(["accessToken": "untrusted", "userId": "1001", "guestRestoreMode": self.mode, "action": "account_reauthenticated", "accountSwitched": optedIn]) }
            expectThrows(try awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }.get())
            assertToken("valid-guest")
        }
    }
    func testSensitive40307KeepsValidRestrictedGuestToken() {
        client = makeClient(); client.setSession("restricted-guest")
        var changes = 0; client.onSessionChanged = { changes += 1 }
        ClientContractProtocol.handle = { _, _ in (403, ["code": 40307, "message": "Authentication required"]) }
        expectThrows(try awaitResult { client.getUserInfo(completion: $0) }.get())
        expectTrue(client.hasSession)
        expectEqual(changes, 0)
        assertToken("restricted-guest")
    }
    func testReentrantSessionChangeDiscardsResolutionWithoutOverwritingNewerToken() {
        client = makeClient(); client.setSession("restricted-guest")
        var redirected = false
        client.onSessionChanged = {
            if !redirected { redirected = true; self.client.setSession("newer-session") }
        }
        ClientContractProtocol.handle = { _, _ in self.success(["accessToken": "reauthenticated", "userId": "1001", "guestRestoreMode": self.mode, "action": "account_reauthenticated", "accountSwitched": false]) }
        expectThrows(try awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }.get())
        assertToken("newer-session")
    }
    func testConfigurationFailurePreservesReauthenticatedTokenForRefreshRetry() throws {
        client = makeClient(); client.setSession("restricted-guest")
        ClientContractProtocol.handle = { request, _ in
            if request.url!.path.hasSuffix("login-or-bind") {
                return self.success(["accessToken": "reauthenticated", "userId": "1001", "guestRestoreMode": self.mode, "action": "account_reauthenticated", "accountSwitched": false])
            }
            return (500, ["code": 50000, "message": "Temporary configuration failure"])
        }
        let result = try awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }.get()
        expectEqual(result["configurationRefreshRequired"] as? Bool, true)
        expectTrue(result["configuration"] is NSNull)
        assertToken("reauthenticated")
    }
    func testGuestLoginRejectsMissingEchoWithoutAcceptingUnsupportedToken() {
        client = makeClient()
        ClientContractProtocol.handle = { _, _ in self.success(["accessToken": "untrusted"]) }
        expectThrows(try awaitResult { client.loginGuest(completion: $0) }.get())
        expectEqual(client.hasSession, false)
    }
    func testDefaultGuestLoginAndLogoutAcceptLegacyServerResponses() throws {
        client = makeClient(optedIn: false)
        ClientContractProtocol.handle = { request, body in
            expectNil(body["guestRestoreMode"])
            if request.url!.path.hasSuffix("login/guest") || request.url!.path.hasSuffix("logout") {
                return self.success(["accessToken": "legacy-guest"])
            }
            return self.success(self.configuration())
        }
        _ = try awaitResult { client.loginGuest(completion: $0) }.get()
        _ = try awaitResult { client.logout(completion: $0) }.get()
        assertToken("legacy-guest")
    }
    func testAccountReadAlsoCarriesConfiguredMode() throws {
        client = makeClient(); client.setSession("guest")
        ClientContractProtocol.handle = { _, body in
            expectEqual(body["guestRestoreMode"] as? String, self.mode)
            return self.success(["sessionType": "guest", "guestRestoreMode": self.mode])
        }
        let account = try awaitResult { client.getAccount(completion: $0) }.get()
        expectEqual(account["sessionType"] as? String, "guest")
    }
    func testUnsupportedInitializationModesAreRejected() throws {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        expectEqual(_NSGetExecutablePath(&buffer, &size), 0)
        let executable = URL(fileURLWithPath: String(cString: buffer))
        for mode in ["", "other", " same_user_restricted"] {
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--unsupported-mode", mode]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            expectTrue(child.terminationStatus != 0)
        }
    }
    func testReauthenticationRejectsNonBooleanAccountSwitchWithoutChangingToken() {
        client = makeClient(); client.setSession("valid-guest")
        for switched in [0, "false", NSNull()] as [Any] {
            ClientContractProtocol.handle = { _, _ in self.success(["accessToken": "untrusted", "userId": "1001", "guestRestoreMode": self.mode, "action": "account_reauthenticated", "accountSwitched": switched]) }
            expectThrows(try awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }.get())
            assertToken("valid-guest")
        }
    }
    func testLegacyResolutionRejectsIncorrectSwitchInBothModes() {
        for optedIn in [false, true] {
            client = makeClient(optedIn: optedIn); client.setSession("valid-guest")
            for (action, switched) in [("guest_upgraded", true), ("existing_account_login", false)] {
                ClientContractProtocol.handle = { _, _ in self.success(["accessToken": "untrusted", "userId": "1001", "guestRestoreMode": self.mode, "action": action, "accountSwitched": switched]) }
                expectThrows(try awaitResult { client.loginOrBindIdentity(["provider": "google"], completion: $0) }.get())
                assertToken("valid-guest")
            }
        }
    }
    func testOptedInGuestLoginFailurePreservesMemoryStorageContextAndCallbacks() {
        client = makeClient(); client.setSession("existing-token")
        var changes = 0; client.onSessionChanged = { changes += 1 }
        let responses: [(Int, [String: Any])] = [
            success(["accessToken": "untrusted"]),
            success(["accessToken": "untrusted", "guestRestoreMode": "other"]),
            success(["guestRestoreMode": mode]),
            (500, ["code": 50000, "message": "Temporary failure"])
        ]
        for index in 0...responses.count {
            MpTracker.shared.runtimeFields = ["user_id": "existing-user", "ab_snapshot": "existing-experiments", "config_version": "existing-config"]
            ClientContractProtocol.transportError = index == responses.count ? URLError(.notConnectedToInternet) : nil
            ClientContractProtocol.handle = { _, _ in responses[index] }
            expectThrows(try awaitResult { client.loginGuest(completion: $0) }.get())
            ClientContractProtocol.transportError = nil
            expectEqual(changes, 0)
            expectTrue(client.hasSession)
            expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String, "existing-user")
            expectEqual(MpTracker.shared.runtimeFields["ab_snapshot"] as? String, "existing-experiments")
            expectEqual(MpTracker.shared.runtimeFields["config_version"] as? String, "existing-config")
            assertToken("existing-token")
            let restored = makeClient()
            expectTrue(restored.hasSession)
            expectNoThrow(try awaitResult { restored.refresh(completion: $0) }.get())
            expectEqual(changes, 0)
        }
    }
    func testDefaultGuestLoginFailureKeepsLegacySessionClearing() {
        client = makeClient(optedIn: false); client.setSession("existing-token")
        var changes = 0; client.onSessionChanged = { changes += 1 }
        ClientContractProtocol.handle = { _, _ in (500, ["code": 50000, "message": "Temporary failure"]) }
        expectThrows(try awaitResult { client.loginGuest(completion: $0) }.get())
        expectEqual(client.hasSession, false)
        expectEqual(makeClient(optedIn: false).hasSession, false)
        expectEqual(changes, 1)
    }
    func testDeletedSessionRecoversFreshGuestAndDoesNotReplayMutations() throws {
        client=makeClient(optedIn:false);client.setSession("deleted")
        var recoveries=0,mutations=0
        ClientContractProtocol.handle={request,body in
            let path=request.url!.path
            if path.hasSuffix("/business-ticket"){mutations += 1}
            if path.hasSuffix("/recover-deleted") {
                recoveries += 1;expectEqual(body["deletedToken"] as? String,"deleted")
                expectEqual((body["device"] as? [String:Any])?["platform"] as? String,"ios")
                return self.success(["accessToken":"fresh-token"])
            }
            if request.value(forHTTPHeaderField:"Authorization")=="Bearer deleted" {return (200,["code":40108])}
            return self.success(["user":["userId":"fresh-guest"],"configVersion":"fresh","experiments":[:]])
        }
        let config=try awaitResult {client.refresh(completion:$0)}.get()
        expectEqual((config["user"] as? [String:Any])?["userId"] as? String,"fresh-guest")
        expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String,"fresh-guest");expectEqual(recoveries,1)
        client.setSession("deleted")
        let result=awaitResult {client.businessTicket(connectionId:"business",completion:$0)}
        switch result {case .failure(let error):expectTrue(error is MpClient.AccountDeletedRecovery);case .success:preconditionFailure("Original mutation must not be replayed")}
        expectEqual(recoveries,2);expectEqual(mutations,1);assertToken("fresh-token")
    }
    func testBlockedAndExpiredSessionsNeverAutoRegister() {
        for code in [40101,40302,40305] {
            client=makeClient(optedIn:false);client.setSession("blocked");var calls=0
            ClientContractProtocol.handle={_,_ in calls += 1;return (200,["code":code])}
            expectThrows(try awaitResult {client.refresh(completion:$0)}.get());expectEqual(calls,1)
        }
    }

    func testAutomaticInitializationCreatesGuestAndRestoresExistingSession() {
        var guests=0
        ClientContractProtocol.handle={request,_ in
            if request.url!.path.hasSuffix("/guest"){guests += 1;return self.success(["accessToken":"automatic"])}
            return self.success(["user":["userId":"auto-guest"],"experiments":[:],"configVersion":"auto"])
        }
        client=makeClient(optedIn:false,autoGuestLogin:true)
        var limit=Date().addingTimeInterval(5)
        while MpTracker.shared.runtimeFields["user_id"] as? String != "auto-guest" && Date()<limit {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        expectEqual(guests,1);expectTrue(client.hasSession);expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String,"auto-guest")
        client=makeClient(optedIn:false,autoGuestLogin:true);limit=Date().addingTimeInterval(5)
        while MpTracker.shared.runtimeFields["user_id"] as? String != "auto-guest" && Date()<limit {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        expectEqual(guests,1);expectEqual(MpTracker.shared.runtimeFields["user_id"] as? String,"auto-guest")
    }
    func testExplicitInitializationAndGuestLoginShareRegistration() throws {
        var guests=0
        ClientContractProtocol.handle={request,_ in
            if request.url!.path.hasSuffix("/guest"){guests += 1;return self.success(["accessToken":"automatic"])}
            return self.success(["user":["userId":"auto-guest"],"experiments":[:],"configVersion":"auto"])
        }
        client=makeClient(optedIn:false,autoGuestLogin:true)
        var manual:Result<[String:Any],Error>?
        client.loginGuest{manual=$0}
        _ = try awaitResult{client.initializeSession(completion:$0)}.get()
        expectEqual(guests,1);expectTrue(manual != nil)
    }

}
