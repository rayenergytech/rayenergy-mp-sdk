import Foundation
import CoreFoundation
import CommonCrypto
import Security

/// Main-thread business facade. Reuses the tracker's installation identity; tokens persist in the installation-scoped Keychain.
public final class MpClient {
    private let paymentEnvironment: String
    private let guestRestoreMode: String?
    private let autoGuestLogin: Bool
    private var autoGuestEligible=false
    private var autoStartupCancelled=false
    public private(set) var initializationError: Error?
    public var onInitializationError: ((Error)->Void)?
    private var initializationWaiters: [(Result<[String:Any],Error>)->Void]=[]
    private var guestLoginWaiters: [(Result<[String:Any],Error>)->Void]=[]
    public func initializeSession(completion:@escaping(Result<[String:Any],Error>)->Void){
        precondition(Thread.isMainThread)
        initializationWaiters.append(completion);guard initializationWaiters.count==1 else{return}
        func finish(_ result:Result<[String:Any],Error>){let callbacks=self.initializationWaiters;self.initializationWaiters=[];callbacks.forEach{$0(result)}}
        if hasSession {refresh(completion:finish)}
        else if !guestLoginWaiters.isEmpty || (autoGuestEligible && !autoStartupCancelled){loginGuest(completion:finish)}
        else {finish(.failure(failure(sessionStorageError == nil ? "Login required" : "Token cache unavailable")))}
    }
    private let apiBase: String
    private let baseContext: [String: Any]
    private var context: [String: Any] {
        return baseContext.merging(tracker.ruleContextSnapshot().mapValues { $0 as Any }) { _, new in new }
    }
    private let tracker: MpTracker
    private var token: String?
    private let handoffStore: MpSessionStore
    private let sessionStore: MpSessionStore
    public private(set) var sessionStorageError: String?
    public var hasSession: Bool { token != nil }
    public var onSessionChanged: (() -> Void)?
    private var renewalWaiters: [(Result<[String: Any], Error>) -> Void] = []
    private var renewing = false
    public struct AccountDeletedRecovery: LocalizedError {
        public let configuration: [String: Any]
        public let code = 40108
        public let sessionRecovered = true
        public var errorDescription: String? { "Account deleted; a new guest session is ready. Retry the operation explicitly." }
    }
    private var recoveringDeleted = false
    private func recoverDeletedSession(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard !recoveringDeleted, let source=token else {completion(.failure(failure("Replacement session unavailable")));return}
        recoveringDeleted=true
        func finish(_ result: Result<[String: Any], Error>) { self.recoveringDeleted=false;completion(result) }
        var expected=epoch+1;setSession(source)
        guard epoch==expected,token==source else {finish(.failure(failure("Session changed; discarded recovery")));return}
        post("/api/v1/client/accounts/recover-deleted",body:["device":accountBody(),"deletedToken":source],authenticated:false){result in
            do {
                let login=try result.get();try self.validateGuestRestore(login)
                guard let next=login["accessToken"] as? String,!next.isEmpty else {throw self.failure("Missing access token")}
                expected=self.epoch+1;self.setSession(next)
                guard self.epoch==expected,self.token==next else {throw self.failure("Session changed; discarded recovery")}
                self.refresh(completion:finish)
            }catch{finish(.failure(error))}
        }
    }
    private var epoch = 0
    private var sequence = 0
    public init(apiBase: String, appCode: String, versionCode: Int? = nil, paymentChannel: String? = nil, contextFields: [String: String] = [:], paymentEnvironment: String = "production", tracker: MpTracker = .shared, guestRestoreMode: String? = nil, autoGuestLogin: Bool = true) {
        precondition(guestRestoreMode == nil || guestRestoreMode == "same_user_restricted", "Unsupported guestRestoreMode")
        self.guestRestoreMode = guestRestoreMode
        self.autoGuestLogin = autoGuestLogin
        let actualCode = DeviceInfo.shared.versionCode
        precondition(versionCode == nil || versionCode == actualCode, "versionCode differs from CFBundleVersion")
        let versionCode = actualCode
        precondition(Thread.isMainThread && MpTracker.shared.isStarted && versionCode >= 0 && versionCode <= Int(Int32.max) && !DeviceInfo.shared.deviceId.isEmpty, "Start MpTracker before MpClient")
        precondition(["production", "sandbox"].contains(paymentEnvironment))
        self.paymentEnvironment = paymentEnvironment
        self.apiBase = apiBase.hasSuffix("/") ? String(apiBase.dropLast()) : apiBase
        self.tracker = tracker
        var body: [String: Any] = ["appCode": appCode, "platform": 1, "versionCode": versionCode, "deviceId": DeviceInfo.shared.deviceId]
        if let channel = paymentChannel { body["paymentChannel"] = channel }
        tracker.setRuleContext(contextFields.filter { ["country", "language", "channel", "adGroup", "adCreative"].contains($0.key) }.mapValues { $0 as Any })
        baseContext = body
        var sessionScope = [self.apiBase, appCode, "1", DeviceInfo.shared.deviceId]
        if !DeviceInfo.shared.sessionScope.isEmpty { sessionScope.append(DeviceInfo.shared.sessionScope) }
        sessionStore = MpSessionStore(scope: sessionScope)
        handoffStore = MpSessionStore(scope: sessionScope + ["handoff"])
        do { token = try sessionStore.read() } catch { token = nil; sessionStorageError = "Token cache unavailable" }
        tracker.runtimeFields = ["user_id": "", "ab_snapshot": "{}", "config_version": ""]
        if tracker.collectionEndpoint == self.apiBase {
            tracker.setCollectionTokenProvider { [weak self] in self?.token }
        } else { tracker.setCollectionTokenProvider(nil) }
        autoGuestEligible=token == nil && sessionStorageError == nil
        let startupEpoch=epoch,startupSequence=sequence
        if autoGuestLogin {DispatchQueue.main.async{[weak self] in
            guard let self=self,self.epoch==startupEpoch,self.sequence==startupSequence,!self.autoStartupCancelled else{return}
            self.initializeSession{result in if case .failure(let error)=result{self.initializationError=error;self.onInitializationError?(error)}}
        }}
    }
    public func setSession(_ accessToken: String?) {
        precondition(Thread.isMainThread)
        epoch += 1; sequence += 1; token = accessToken.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        do { try sessionStore.write(token); sessionStorageError = nil }
        catch { sessionStorageError = "Token cache unavailable"; try? sessionStore.write(nil) }
        tracker.runtimeFields = ["user_id": "", "ab_snapshot": "{}", "config_version": ""]
        onSessionChanged?()
    }
    public func clearLocalSession() { tracker.cancelStartupIdentity(); setSession(nil) }
    private func failure(_ message: String) -> NSError { NSError(domain: "MpClient", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func validateGuestRestore(_ login: [String: Any]) throws {
        if let requested = guestRestoreMode, login["guestRestoreMode"] as? String != requested {
            throw failure("Server does not support requested guestRestoreMode")
        }
    }
    private func post(_ path: String, body: [String: Any], authenticated: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        precondition(Thread.isMainThread)
        let generation = epoch
        guard !authenticated || token != nil else { completion(.failure(failure("Login required"))); return }
        guard let url = URL(string: apiBase + path) else { completion(.failure(failure("Invalid API URL"))); return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(paymentEnvironment, forHTTPHeaderField: "X-Payment-Environment")
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let credential = token { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        var payload = body
        if (path.hasPrefix("/api/v1/client/accounts/") && path != "/api/v1/client/accounts/recover-deleted") || path == "/api/v1/client/users/login/guest" {
            // The configured option, including its absence, takes precedence over caller proof fields.
            payload["guestRestoreMode"] = guestRestoreMode
        }
        do { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        catch { completion(.failure(error)); return }
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard generation == self.epoch else { completion(.failure(self.failure("Session changed; discarded response"))); return }
                do {
                    if let error = error { throw error }
                    if authenticated,let data=data,let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],object["code"] as? Int==40108 {
                        self.recoverDeletedSession { result in completion(result.flatMap { .failure(AccountDeletedRecovery(configuration:$0)) }) };return
                    }
                    if authenticated, let status = response as? HTTPURLResponse, status.statusCode == 401 { self.autoGuestEligible=false;self.clearLocalSession(); throw self.failure("Login expired") }
                    guard let data = data, let status = response as? HTTPURLResponse,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw self.failure("Invalid response") }
                    if authenticated && (status.statusCode == 401 || object["code"] as? Int == 40101 || object["code"] as? Int == 40302) { self.autoGuestEligible=false;self.clearLocalSession() }
                    guard (200..<300).contains(status.statusCode), object["code"] as? Int == 0,
                          let value = object["data"] as? [String: Any] else { throw self.failure(object["message"] as? String ?? "Request failed") }
                    completion(.success(value))
                } catch { completion(.failure(error)) }
            }
        }.resume()
    }
    public func loginGuest(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guestLoginWaiters.append(completion);guard guestLoginWaiters.count==1 else{return}
        loginGuestImpl {result in let callbacks=self.guestLoginWaiters;self.guestLoginWaiters=[];callbacks.forEach{$0(result)}}
    }
    private func loginGuestImpl(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if guestRestoreMode == nil { setSession(nil) }
        post("/api/v1/client/users/login/guest", body: accountBody(), authenticated: false) { result in
            switch result {
            case .success(let login):
                do { try self.validateGuestRestore(login) } catch { completion(.failure(error)); return }
                guard let token = login["accessToken"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(.failure(self.failure("Missing access token"))); return }
                self.autoGuestEligible=false;self.setSession(token); self.refresh(completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        }
    }
    private func accountBody(_ fields: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = ["appCode": context["appCode"]!, "deviceId": context["deviceId"]!, "platform": "ios"]
        if let country = context["country"] { body["country"] = country }; fields.forEach { body[$0.key] = $0.value }; body["appCode"] = context["appCode"]!; body["deviceId"] = context["deviceId"]!; body["platform"] = "ios"; body["guestRestoreMode"] = guestRestoreMode; body["channel"] = context["channel"] ?? "organic"; return body
    }
    private func changeAccount(_ path: String, fields: [String: Any] = [:], authenticated: Bool = true, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if !authenticated {autoStartupCancelled=true;if !guestLoginWaiters.isEmpty{setSession(token)}}
        post("/api/v1/client/accounts/" + path, body: accountBody(fields), authenticated: authenticated) { result in
            if path=="session/refresh",case .failure(let error)=result,let recovery=error as? AccountDeletedRecovery {completion(.success(recovery.configuration));return}
            switch result {
            case .success(let login):
                do { try self.validateGuestRestore(login) } catch { completion(.failure(error)); return }
                guard let token = login["accessToken"] as? String, !token.isEmpty else { completion(.failure(self.failure("Missing access token"))); return }
                self.setSession(token); self.refresh(completion: completion)
            case .failure(let error): completion(.failure(error))
            }
        }
    }
    private func handoff(_ action: String, fields: [String: Any] = [:], authenticated: Bool = false, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        post("/api/v1/client/handoff/" + action, body: accountBody(fields), authenticated: authenticated, completion: completion)
    }
    public func getAppHandoffSource(completion: @escaping (Result<[String: Any], Error>) -> Void) { handoff("current", authenticated:true, completion:completion) }
    public func handoffConfig(completion: @escaping (Result<[String: Any], Error>) -> Void) { handoff("config", completion: completion) }
    private func handoffHash(_ value: String) -> String {
        let bytes=Array(value.utf8);var digest=[UInt8](repeating:0,count:Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { pointer in _ = CC_SHA256(pointer.baseAddress, CC_LONG(bytes.count), &digest) }
        return digest.map {String(format:"%02x",$0)}.joined()
    }
    private func pendingHandoff() throws -> [String: Any] {
        guard let value=try handoffStore.read(),let data=value.data(using:.utf8),let object=try JSONSerialization.jsonObject(with:data) as? [String: Any] else {throw failure("No pending handoff")};return object
    }
    private func saveHandoff(_ value: [String: Any]?) throws {
        guard let value=value else {try handoffStore.write(nil);return}
        let data=try JSONSerialization.data(withJSONObject:value);guard let text=String(data:data,encoding:.utf8) else {throw failure("Pending storage failed")};try handoffStore.write(text)
    }
    private func handoffBody(_ p: [String: Any]) -> [String: Any] { ["claimId":p["claimId"] ?? "","verifier":p["verifier"] ?? ""] }
    /// Pass both cold-start and running-app URLs, or the provider's resolved callback payload.
    public func resolveAppHandoff(_ url: URL?, provider: String? = nil, payload: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        handoffConfig { result in
            do {
                let config=try result.get();guard config["protocolVersion"] as? Int == 1,config["enabled"] as? Bool == true else {throw self.failure("Handoff unavailable")}
                var id: String?
                if let provider=provider {
                    guard provider == config["provider"] as? String,["appsflyer","adjust"].contains(provider),let parameter=config["parameter"] as? String else {throw self.failure("Provider mismatch")}
                    if provider == "appsflyer" {id=payload[parameter] as? String}
                    else if let url=url {id=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name==parameter})?.value}
                } else {
                    guard let url=url,let baseText=config["baseUrl"] as? String,let base=URL(string:baseText) else {throw self.failure("Invalid URL")}
                    let items=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
                    let scheme=config["scheme"] as? String ?? ""
                    let custom = !scheme.isEmpty && url.scheme == scheme && url.host == "handoff"
                    let allowed: Bool
                    if custom {allowed = items.first(where:{$0.name=="appCode"})?.value == (self.context["appCode"] as? String)}
                    else {allowed = url.scheme == "https" && url.host == base.host && url.port == base.port && url.path == "/api/v1/public/handoff/" + (self.context["appCode"] as? String ?? "")}
                    guard allowed else {throw self.failure("Untrusted handoff URL")}
                    id=items.first(where:{$0.name=="handoffId"})?.value
                }
                guard let id=id,id.range(of:"^[A-Za-z0-9_-]{20,64}$",options:.regularExpression) != nil else {throw self.failure("Missing handoff context")}
                self.handoff("resolve",fields:["handoffId":id]) { resolved in completion(resolved.map {var data=$0;data["handoffId"]=id;return data}) }
            } catch {completion(.failure(error))}
        }
    }
    public func beginAppHandoff(_ handoffId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            var p: [String: Any]
            if let stored=try handoffStore.read(),let data=stored.data(using:.utf8),let pending=try JSONSerialization.jsonObject(with:data) as? [String: Any] {p=pending}
            else {
                var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw failure("Secure crypto unavailable")}
                p=["claimId":UUID().uuidString.lowercased(),"handoffId":handoffId,"verifier":bytes.map {String(format:"%02x",$0)}.joined(),"oldTokenHash":handoffHash(token ?? "")]
            }
            guard p["handoffId"] as? String == handoffId,let verifier=p["verifier"] as? String else {throw failure("Cancel existing handoff first")}
            try saveHandoff(p)
            handoff("claim",fields:["claimId":p["claimId"] ?? "","handoffId":handoffId,"challenge":handoffHash(verifier)],authenticated:hasSession,completion:completion)
        } catch {completion(.failure(error))}
    }
    public func appHandoffStatus(completion: @escaping (Result<[String: Any], Error>) -> Void) {do {handoff("status",fields:handoffBody(try pendingHandoff()),completion:completion)}catch {completion(.failure(error))}}
    public func cancelAppHandoff(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {handoff("cancel",fields:handoffBody(try pendingHandoff())) {result in do {let value=try result.get();try self.saveHandoff(nil);completion(.success(value))}catch{completion(.failure(error))}}}catch {completion(.failure(error))}
    }
    public func completeAppHandoff(switchConfirmed: Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            guard switchConfirmed else {throw failure("Explicit switch confirmation required")}
            var p=try pendingHandoff();let current=handoffHash(token ?? ""),generation=epoch
            guard current == p["oldTokenHash"] as? String || current == p["newTokenHash"] as? String else {throw failure("Session changed; start a new handoff")}
            var body=handoffBody(p);body["switchConfirmed"]=true
            handoff("status",fields:body) {result in
                do {
                    let state=try result.get()
                    if ["acknowledged","delivered","recovery_expired"].contains(state["status"] as? String ?? ""),current == p["newTokenHash"] as? String {
                        self.getAccount {account in
                            do {
                                let value=try account.get();guard value["userId"] as? String == p["newUserId"] as? String else {throw self.failure("Handoff account mismatch")}
                                self.tracker.runtimeFields["user_id"]=value["userId"]
                                if state["status"] as? String == "acknowledged" {try self.saveHandoff(nil);completion(.success(value))}
                                else {self.handoff("ack",fields:body,authenticated:true) {result in do {_ = try result.get();try self.saveHandoff(nil);completion(.success(value))}catch{completion(.failure(error))}}}
                            } catch {completion(.failure(error))}
                        };return
                    }
                    self.handoff("redeem",fields:body) {result in
                        do {
                            let login=try result.get();guard generation == self.epoch,let credential=login["accessToken"] as? String,!credential.isEmpty,let user=login["userId"] as? String else {throw self.failure("Session changed or invalid handoff session")}
                            p["newTokenHash"]=self.handoffHash(credential);p["newUserId"]=user;try self.saveHandoff(p)
                            // Persist before mutation; failure preserves the previous credentials.
                            try self.sessionStore.write(credential);self.token=credential;self.epoch += 1;self.sequence += 1;self.sessionStorageError=nil
                            self.tracker.runtimeFields=["user_id":"","ab_snapshot":"{}","config_version":""];self.onSessionChanged?()
                            self.getAccount {result in
                                do {
                                    let account=try result.get();guard account["userId"] as? String == user else {throw self.failure("Handoff account mismatch")}
                                    self.tracker.runtimeFields["user_id"]=user
                                    self.handoff("ack",fields:body,authenticated:true) {result in do {_ = try result.get();try self.saveHandoff(nil);completion(.success(login))}catch{completion(.failure(error))}}
                                } catch {completion(.failure(error))}
                            }
                        } catch {completion(.failure(error))}
                    }
                } catch {completion(.failure(error))}
            }
        } catch {completion(.failure(error))}
    }
    public func reportAppHandoff(_ eventType: String, handoffId: String? = nil, eventId: String = UUID().uuidString.lowercased(), completion: @escaping (Result<[String: Any], Error>) -> Void) {
        handoff("event",fields:["eventType":eventType,"handoffId":handoffId ?? "","eventId":eventId],completion:completion)
    }
    public func getAccount(completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/current", body: [:], authenticated: true, completion: completion) }
    public func requestVerification(provider: String, identifier: String, purpose: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/verification", body: accountBody(["provider":provider,"identifier":identifier,"purpose":purpose]), authenticated: purpose != "login" && purpose != "reset", completion: completion) }
    public func loginMethods(completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/login-methods", body: accountBody(), authenticated: false, completion: completion) }
    public func oauthChallenge(provider: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/oauth/challenge", body: accountBody(["provider":provider]), authenticated: false, completion: completion) }
    public func loginIdentity(_ proof: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) { changeAccount("login", fields: proof, authenticated: false, completion: completion) }
    public func loginPassword(email: String, password: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { changeAccount("password/login", fields: ["identifier":email,"password":password], authenticated: false, completion: completion) }
    public func loginOrBindIdentity(_ proof: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        post("/api/v1/client/accounts/login-or-bind", body: accountBody(proof), authenticated: true) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let login):
                do { try self.validateGuestRestore(login) } catch { completion(.failure(error)); return }
                // JSON number 0 also bridges to Bool; reauthentication requires an actual JSON boolean.
                guard let token=login["accessToken"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let user=login["userId"] as? String, !user.isEmpty, let action=login["action"] as? String,
                      let switchedValue=login["accountSwitched"], let switched=switchedValue as? Bool,
                      (["guest_upgraded","existing_account_login"].contains(action) || (self.guestRestoreMode != nil && action == "account_reauthenticated" && CFGetTypeID(switchedValue as CFTypeRef) == CFBooleanGetTypeID())),
                      switched == (action == "existing_account_login") else { completion(.failure(self.failure("Invalid identity resolution")));return }
                let generation=self.epoch+1;self.setSession(token)
                guard generation==self.epoch,self.token==token else { completion(.failure(self.failure("Session changed; discarded response")));return }
                self.tracker.runtimeFields=["user_id":user,"ab_snapshot":"{}","config_version":""]
                self.refresh { configured in
                    guard generation==self.epoch, self.token != nil else { completion(.failure(self.failure("Session changed; discarded response")));return }
                    var output=login
                    switch configured {
                    case .success(let config): output["configuration"]=config;output["configurationRefreshRequired"]=false
                    case .failure: output["configuration"]=NSNull();output["configurationRefreshRequired"]=true
                    }
                    completion(.success(output))
                }
            }
        }
    }
    public func bindIdentity(_ proof: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) { changeAccount("bind", fields: proof, completion: completion) }
    public func replaceIdentity(previous: [String: Any], replacement: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) { changeAccount("replace", fields: ["previous":accountBody(previous),"replacement":accountBody(replacement)], completion: completion) }
    public func unbindIdentity(_ proof: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) { changeAccount("unbind", fields: proof, completion: completion) }
    public func renewSession(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        precondition(Thread.isMainThread)
        renewalWaiters.append(completion); if renewing { return }; renewing = true
        changeAccount("session/refresh") { result in
            let callbacks = self.renewalWaiters; self.renewalWaiters = []; self.renewing = false
            let generation = self.epoch
            for callback in callbacks { callback(generation == self.epoch ? result : .failure(self.failure("Session changed"))) }
        }
    }
    public func renewSessionForBusiness(connectionId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        renewSession { result in
            switch result { case .success: self.businessTicket(connectionId: connectionId, completion: completion); case .failure(let error): completion(.failure(error)) }
        }
    }
    public func loginBusiness(connectionId: String, exchangeTicket: @escaping (String, @escaping (Result<[String: Any], Error>) -> Void) -> Void, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        precondition(Thread.isMainThread)
        let generation = epoch
        businessTicket(connectionId: connectionId) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let payload):
                guard generation == self.epoch else { completion(.failure(self.failure("Session changed; discarded business ticket"))); return }
                guard let ticket = payload["ticket"] as? String, !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(.failure(self.failure("Missing ticket"))); return }
                exchangeTicket(ticket) { businessResult in DispatchQueue.main.async {
                    completion(generation == self.epoch ? businessResult : .failure(self.failure("Session changed; discarded business response")))
                } }
            }
        }
    }
    public func logout(allDevices: Bool = false, completion: @escaping (Result<[String: Any], Error>) -> Void) { changeAccount("logout" + (allDevices ? "?allDevices=true" : ""), completion: completion) }
    public func getSessions(completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/sessions", body: [:], authenticated: true, completion: completion) }
    public func revokeSession(_ id: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/sessions/revoke", body: ["sessionId":id], authenticated: true, completion: completion) }
    public func businessTicket(connectionId: String, completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/business-ticket", body: ["connectionId":connectionId], authenticated: true, completion: completion) }
    public func resetPassword(_ proof: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/password/reset", body: accountBody(proof), authenticated: false, completion: completion) }
    public func deletionPrecheck(completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/deletion/precheck", body: [:], authenticated: true, completion: completion) }
    public func deleteAccount(_ proof: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        post("/api/v1/client/accounts/deletion", body: accountBody(proof), authenticated: true) { result in
            if case .success = result { self.clearLocalSession() }; completion(result)
        }
    }
    public func deletionStatus(_ receipt: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) { post("/api/v1/client/accounts/deletion/status", body: receipt, authenticated: false, completion: completion) }
    public func getUserInfo(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if autoGuestLogin && !hasSession && !autoStartupCancelled && (!guestLoginWaiters.isEmpty || autoGuestEligible){loginGuest{result in completion(result.flatMap{value in guard let user=value["user"] as? [String:Any] else{return .failure(self.failure("Missing user"))};return .success(user)})};return}
        post("/api/v1/client/runtime/user", body: context, authenticated: true) {result in
            if case .failure(let error)=result,let recovery=error as? AccountDeletedRecovery,let user=recovery.configuration["user"] as? [String:Any] {completion(.success(user));return};completion(result)
        }
    }
    public func refresh(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if autoGuestLogin && !hasSession && !autoStartupCancelled && (!guestLoginWaiters.isEmpty || autoGuestEligible){loginGuest(completion:completion);return}
        precondition(Thread.isMainThread); sequence += 1; let request = sequence
        post("/api/v1/client/runtime/config", body: context, authenticated: true) { result in
            if case .failure(let error)=result,let recovery=error as? AccountDeletedRecovery {completion(.success(recovery.configuration));return}
            guard request == self.sequence else { completion(.failure(self.failure("Superseded response"))); return }
            if case .success(let value) = result, let user = value["user"] as? [String: Any], let id = user["userId"] as? String {
                let ab = (try? JSONSerialization.data(withJSONObject: value["experiments"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
                self.tracker.runtimeFields = ["user_id": id, "ab_snapshot": String(data: ab, encoding: .utf8) ?? "{}", "config_version": value["configVersion"] as? String ?? ""]
            }
            completion(result)
        }
    }
}
