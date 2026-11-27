import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'core.dart';
import 'flutter_tracker.dart';

/// A decoded API response that did not complete the requested operation.
class MpApiException extends StateError {
  MpApiException(super.message, {required this.statusCode, this.code});

  final int statusCode;
  final int? code;
}

/// The old operation was not replayed. A fresh guest is ready for subsequent requests.
class MpAccountDeletedRecovery implements Exception {
  MpAccountDeletedRecovery(this.configuration,this.epoch,this.sequence);
  final JsonMap configuration;
  final int epoch,sequence;
  int get code=>40108;
  bool get sessionRecovered=>true;
  @override String toString()=>'Account deleted; a new guest session is ready. Retry the operation explicitly.';
}

abstract interface class MpSessionStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureMpSessionStorage implements MpSessionStorage {
  const SecureMpSessionStorage([this.storage=const FlutterSecureStorage()]);
  final FlutterSecureStorage storage;
  @override Future<String?> read(String key)=>storage.read(key:key);
  @override Future<void> write(String key,String value)=>storage.write(key:key,value:value);
  @override Future<void> delete(String key)=>storage.delete(key:key);
}

/// Business facade sharing the tracker's actual client and installation identity.
class MpClient {
  MpClient({required this.tracker, required String apiBase, required String appCode,
    int? versionCode, this.guestRestoreMode, this.autoGuestLogin=true, this.webRecovery=false, this.onInitializationError, this.paymentEnvironment='production', String? paymentChannel, JsonMap contextFields=const {}, http.Client? transport, MpSessionStorage? sessionStorage})
    : _base=apiBase.replaceFirst(RegExp(r'/$'), ''), _http=transport??http.Client(), _ownsHttp=transport==null,
      _sessionStorage=sessionStorage??const SecureMpSessionStorage(),
      _baseContext={'appCode':appCode,'platform':tracker.clientPlatform,'deviceId':tracker.deviceId,
        'versionCode':versionCode ?? tracker.versionCode,if(paymentChannel!=null)'paymentChannel':paymentChannel} {
    if (guestRestoreMode != null && guestRestoreMode != 'same_user_restricted') throw ArgumentError('Invalid guestRestoreMode');
    if (tracker.versionCode == null) throw StateError('Configure tracker appVersionCode before creating MpClient');
    final actualCode = versionCode ?? tracker.versionCode;
    if (tracker.versionCode != null && versionCode != null && tracker.versionCode != versionCode) throw ArgumentError('versionCode differs from tracker build code');
    if (actualCode == null || actualCode<0 || actualCode>2147483647 || appCode.isEmpty) throw ArgumentError('Invalid APP or versionCode');
    tracker.setRuleContext({for(final key in ['country','language','channel','adGroup','adCreative']) if(contextFields.containsKey(key)) key:contextFields[key]});
    _sessionKey='mp_client_session_v1:'+base64Url.encode(utf8.encode(jsonEncode([_base,appCode,tracker.clientPlatform,tracker.deviceId,if(tracker.sessionScope.isNotEmpty)tracker.sessionScope])));
    tracker.setRuntimeContext(null,{'user_id':'','ab_snapshot':'{}','config_version':''});
    tracker.setCollectionTokenProvider(tracker.collectionEndpoint == _base ? () => _closed ? null : _token : null);
    _ready=_restore();
    final startupEpoch=_epoch,startupSequence=_sequence;
    _startupReady=Future<void>(()async{
      await _ready;
      if(!autoGuestLogin||_closed||_autoStartupCancelled)return;
      if(_guestLogin!=null){await _guestLogin;return;}
      if(startupEpoch!=_epoch||startupSequence!=_sequence)return;
      await initializeSession();
    });
    _startupReady.then<void>((_) {},onError:(Object error,StackTrace stack){initializationError=error;try{onInitializationError?.call(error);}catch(_){}});
  }
  final String paymentEnvironment;
  final String? guestRestoreMode;
  final bool autoGuestLogin;
  final bool webRecovery;
  final void Function(Object error)? onInitializationError;
  Object? initializationError;
  bool _autoGuestEligible=false,_autoStartupCancelled=false;
  late final Future<void> _startupReady;
  Future<JsonMap>? _initialization,_guestLogin;
  final MpTracker tracker;
  final String _base;
  final http.Client _http;
  final bool _ownsHttp;
  final JsonMap _baseContext;
  JsonMap get _context => {..._baseContext, ...tracker.ruleContext};
  final MpSessionStorage _sessionStorage;
  late final String _sessionKey;
  late final Future<void> _ready;
  Future<void> _writes=Future<void>.value();
  String? sessionStorageError;
  Future<void> get ready=>_startupReady;
  Future<JsonMap> initializeSession()=>_initialization ??= Future<JsonMap>(()async{
    await _ready;
    if(_closed)throw StateError('Client closed');
    if(_guestLogin!=null)return _guestLogin!;
    if(_token!=null)return refresh();
    if(_autoStartupCancelled)throw StateError('Session initialization superseded by explicit login');
    if(sessionStorageError!=null)throw StateError('Token cache unavailable; retry storage or explicitly login');
    if(!_autoGuestEligible)throw StateError('Login required');
    return loginGuest();
  }).whenComplete((){_initialization=null;});
  bool get hasSession=>_token!=null;
  String? _token;
  Future<void> _restore() async {
    final generation=_epoch;
    try {
      final token=await tracker.measureOperation('client.session_restore', () => _sessionStorage.read(_sessionKey));
      if(!_closed&&generation==_epoch){_token=token==null||token.trim().isEmpty?null:token;_autoGuestEligible=_token==null;}
    } catch(_){sessionStorageError='Token cache unavailable';}
  }
  void Function()? onSessionChanged;
  Future<JsonMap>? _renewal;
  Future<JsonMap>? _deletedRecovery;
  String? _deletedRecoveryToken;
  Future<JsonMap> _recoverDeletedSession() {
    if(_deletedRecovery!=null)return _deletedRecovery!;
    final source=_token;_deletedRecoveryToken=source;
    return _deletedRecovery=Future<JsonMap>(() async {
      if(source==null||_closed||_token!=source)throw StateError('Session changed; discarded recovery');
      var generation=_epoch+1;await setSession(source);
      if(generation!=_epoch||_token!=source)throw StateError('Session changed; discarded recovery');
      final device=_accountBody();if(tracker.clientPlatform==3)device['webContext']=tracker.webIdentityContext;
      final login=await _post('/api/v1/client/accounts/recover-deleted',{'device':device,'deletedToken':source},authenticated:false);
      if(generation!=_epoch)throw StateError('Session changed; discarded recovery');
      _validateGuestRestoreMode(login);final token=login['accessToken'];
      if(token is! String||token.trim().isEmpty)throw StateError('Missing access token');
      generation=_epoch+1;await setSession(token);
      if(generation!=_epoch||_token!=token)throw StateError('Session changed; discarded recovery');
      final configuration=await refresh();
      return {'configuration':configuration,'epoch':_epoch,'sequence':_sequence};
    }).whenComplete((){_deletedRecovery=null;_deletedRecoveryToken=null;});
  }
  int _epoch=0, _sequence=0;
  bool _closed=false;
  Future<void> setSession(String? token) {
    if(_closed)throw StateError('Client closed');
    _epoch++;_sequence++;_token=token==null||token.trim().isEmpty?null:token;
    try { onSessionChanged?.call(); } catch (_) {}
    final value=_token;
    tracker.setRuntimeContext(null,{'user_id':'','ab_snapshot':'{}','config_version':''});
    _writes=_writes.then((_) async {
      await _ready;
      try {
        if(value==null)await _sessionStorage.delete(_sessionKey);
        else await _sessionStorage.write(_sessionKey,value);
        sessionStorageError=null;
      } catch(_){sessionStorageError='Token cache unavailable';try{await _sessionStorage.delete(_sessionKey);}catch(_){} }
    });
    return _writes;
  }
  Future<void> clearLocalSession(){tracker.cancelStartupIdentity();return setSession(null);}
  Future<JsonMap> _post(String path, JsonMap body, {bool authenticated=true}) async {
    if(_closed)throw StateError('Client closed');
    if(!['production','sandbox'].contains(paymentEnvironment))throw ArgumentError('Invalid paymentEnvironment');
    final generation=_epoch;
    await _ready;await _writes;
    if(_closed||generation!=_epoch)throw StateError('Session changed; discarded request');
    final credential=_token;
    if(authenticated && credential==null)throw StateError('Login required');
    final response=await tracker.measureOperation(path.endsWith('/runtime/config')?'client.runtime_config':path.endsWith('/login/guest')?'client.guest_login':'client.request', () => _http.post(Uri.parse('$_base$path'),headers:{'Content-Type':'application/json','X-Payment-Environment':paymentEnvironment,if(authenticated)'Authorization':'Bearer $credential',if(authenticated&&tracker.recoveryId!=null)'X-Guest-Recovery-Id':tracker.recoveryId!},body:jsonEncode(body)).timeout(const Duration(seconds:15)));
    if(generation!=_epoch)throw StateError('Session changed; discarded response');
    final Object? decoded;
    try{decoded=jsonDecode(response.body);}catch(_){if(authenticated&&response.statusCode==401){_autoGuestEligible=false;await clearLocalSession();}rethrow;}
    final statusCode = response.statusCode;
    final bodyMap = decoded is Map ? decoded : null;
    final rawCode = bodyMap?['code'];
    final code = rawCode is int ? rawCode : null;
    if(authenticated&&code==40108){
      if(_deletedRecovery!=null&&_deletedRecoveryToken!=_token)throw StateError('Replacement session unavailable');
      final recovered=await _recoverDeletedSession();if(_closed||recovered['epoch']!=_epoch)throw StateError('Session changed; discarded recovery');
      throw MpAccountDeletedRecovery(Map<String,Object?>.from(recovered['configuration'] as Map),_epoch,recovered['sequence'] as int);
    }
    if(authenticated&&(statusCode==401||code==40101||code==40302)){
      _autoGuestEligible=false;
      await clearLocalSession();
      final message = statusCode==401 ? 'Login expired' : bodyMap?['message']?.toString()??'Login expired';
      throw MpApiException(message,statusCode:statusCode,code:code);
    }
    final data = bodyMap?['data'];
    if(statusCode<200 || statusCode>=300 || code!=0 || data is! Map){
      final message = bodyMap==null ? 'Invalid response' : bodyMap['message']?.toString()??'Request failed';
      throw MpApiException(message,statusCode:statusCode,code:code);
    }
    return Map<String,Object?>.from(data);
  }
  Future<JsonMap> loginGuest() {
    if(_guestLogin!=null)return _guestLogin!;
    final complete=Completer<JsonMap>();_guestLogin=complete.future;
    _loginGuestImpl().then((value){_guestLogin=null;complete.complete(value);},onError:(Object error,StackTrace stack){_guestLogin=null;complete.completeError(error,stack);});
    return complete.future;
  }
  Future<JsonMap> _loginGuestImpl() async {
    final clearing=guestRestoreMode==null?setSession(null):Future<void>.value(), generation=_epoch;
    await clearing;
    if(generation!=_epoch)throw StateError('Session changed; discarded request');
    final login=await _post('/api/v1/client/users/login/guest',{'channel':_context['channel']??'organic',if(tracker.clientPlatform==3)'webContext':{...tracker.webIdentityContext,if(webRecovery)'recoveryConfirmation':true},if(guestRestoreMode!=null)'guestRestoreMode':guestRestoreMode,'appCode':_context['appCode'],'deviceId':tracker.deviceId,if(tracker.recoveryId!=null)'recoveryId':tracker.recoveryId,'platform':{1:'ios',2:'android',3:'web'}[tracker.clientPlatform],if(_context['country']!=null)'country':_context['country']},authenticated:false);
    if(generation!=_epoch)throw StateError('Session changed; discarded response');
    _validateGuestRestoreMode(login);
    final token=login['accessToken'];if(token is! String||token.trim().isEmpty)throw StateError('Missing access token');
    _autoGuestEligible=false;
    await setSession(token);return refresh();
  }
  JsonMap _accountBody([JsonMap fields=const {}])=>{if(_context['country']!=null)'country':_context['country'],for(final entry in fields.entries) if(entry.key!='guestRestoreMode') entry.key:entry.value,if(guestRestoreMode!=null)'guestRestoreMode':guestRestoreMode,'appCode':_context['appCode'],'deviceId':tracker.deviceId,if(tracker.recoveryId!=null)'recoveryId':tracker.recoveryId,'platform':{1:'ios',2:'android',3:'web'}[tracker.clientPlatform],'channel':_context['channel']??'organic'};
  void _validateGuestRestoreMode(JsonMap login) {
    if(guestRestoreMode!=null && login['guestRestoreMode']!=guestRestoreMode)throw StateError('Unsupported guest restore mode: server did not confirm $guestRestoreMode');
  }
  Future<JsonMap> _changeAccount(String path,JsonMap proof,{bool authenticated=true}) async {
    if(!authenticated){_autoStartupCancelled=true;if(_guestLogin!=null)await setSession(_token);}
    final generation=_epoch;
    final login=await _post('/api/v1/client/accounts/$path',_accountBody(proof),authenticated:authenticated);
    if(generation!=_epoch)throw StateError('Session changed; discarded response');
    _validateGuestRestoreMode(login);
    final token=login['accessToken'];if(token is! String||token.isEmpty)throw StateError('Missing access token');
    await setSession(token);return refresh();
  }
  Future<JsonMap> getAccount()=>_post('/api/v1/client/accounts/current',{});
  Future<JsonMap> requestVerification(String provider,String identifier,String purpose)=>_post('/api/v1/client/accounts/verification',_accountBody({'provider':provider,'identifier':identifier,'purpose':purpose}),authenticated:purpose!='login'&&purpose!='reset');
  Future<JsonMap> loginMethods()=>_post('/api/v1/client/accounts/login-methods',_accountBody({}),authenticated:false);
  Future<JsonMap> oauthChallenge(String provider)=>_post('/api/v1/client/accounts/oauth/challenge',_accountBody({'provider':provider}),authenticated:false);
  Future<JsonMap> loginIdentity(JsonMap proof)=>_changeAccount('login',proof,authenticated:false);
  Future<JsonMap> loginPassword(String email,String password)=>_changeAccount('password/login',{'identifier':email,'password':password},authenticated:false);
  String _handoffHash(String value)=>sha256.convert(utf8.encode(value)).toString();
  Future<JsonMap> _handoff(String action, [JsonMap fields=const {},bool authenticated=false])=>_post('/api/v1/client/handoff/$action',_accountBody(fields),authenticated:authenticated);
  Future<JsonMap> getAppHandoffSource()=>_handoff('current',{},true);
  Future<JsonMap> handoffConfig()=>_handoff('config');
  Future<JsonMap> createAppHandoff({String routeKey='home',JsonMap source=const {}})=>_handoff('create',{'routeKey':routeKey,'source':source},true);
  Future<JsonMap> createWebRecovery() async {
    if(tracker.clientPlatform!=3)throw StateError('Web client required');
    return _handoff('web-recovery/create',{},true);
  }
  Future<List<dynamic>> pendingAppHandoffs() async {
    final value=await _handoff('pending',{},true);return value['claims'] as List<dynamic>? ?? [];
  }
  Future<JsonMap> confirmAppHandoff(String claimId,String pairCode,{required bool approve})=>_handoff('approve',{'claimId':claimId,'pairCode':pairCode,'approve':approve},true);
  Future<JsonMap?> _pendingHandoff() async {final value=await _sessionStorage.read('$_sessionKey:handoff');return value==null?null:Map<String,dynamic>.from(jsonDecode(value) as Map);}
  Future<void> _saveHandoff(JsonMap? value)=>value==null?_sessionStorage.delete('$_sessionKey:handoff'):_sessionStorage.write('$_sessionKey:handoff',jsonEncode(value));
  JsonMap _handoffBody(JsonMap pending)=>{'claimId':pending['claimId'],'verifier':pending['verifier']};
  String _handoffRandom(int length)=>List.generate(length,(_)=>Random.secure().nextInt(256).toRadixString(16).padLeft(2,'0')).join();
  Future<JsonMap> resolveAppHandoff({Uri? uri,String? provider,JsonMap payload=const {}}) async {
    final config=await handoffConfig();if(config['protocolVersion']!=1||config['enabled']!=true)throw StateError('Handoff unavailable');
    String? id;
    if(provider!=null){
      if(provider!=config['provider']||!['appsflyer','adjust'].contains(provider))throw StateError('Provider mismatch');
      final parameter=config['parameter'] as String;
      id=provider=='appsflyer'?(payload[parameter] as String?) : uri?.queryParameters[parameter];
    }else{
      final base=Uri.parse(config['baseUrl'] as String),scheme=config['scheme'] as String? ?? '';
      if(uri==null)throw ArgumentError('Missing URL');
      final custom=scheme.isNotEmpty&&uri.scheme==scheme&&uri.host=='handoff';
      if(custom?uri.queryParameters['appCode']!=_context['appCode']:uri.scheme!='https'||uri.host!=base.host||uri.port!=base.port||uri.path!='/api/v1/public/handoff/${_context['appCode']}')throw StateError('Untrusted handoff URL');
      id=uri.queryParameters['handoffId'];
    }
    if(id==null||!RegExp(r'^[A-Za-z0-9_-]{20,64}$').hasMatch(id))throw ArgumentError('Missing handoff context');
    return {...await _handoff('resolve',{'handoffId':id}),'handoffId':id};
  }
  Future<JsonMap> beginAppHandoff(String handoffId) async {
    if(tracker.clientPlatform==3)throw StateError('Native client required');
    return _beginHandoff(handoffId);
  }
  Future<JsonMap> beginWebRecovery(String handoffId) async {
    if(tracker.clientPlatform!=3)throw StateError('Web client required');
    if(!RegExp(r'^[A-Za-z0-9_-]{20,64}$').hasMatch(handoffId))throw ArgumentError('Invalid recovery identifier');
    _autoStartupCancelled=true;
    final startupGuest=_guestLogin;
    if(startupGuest!=null){try{await startupGuest;}catch(_){}}
    return _beginHandoff(handoffId);
  }
  Future<JsonMap> _beginHandoff(String handoffId) async {
    await _ready;await _writes;
    final generation=_epoch;
    var p=await _pendingHandoff();
    if(p==null){final raw=_handoffRandom(16);p={'claimId':'${raw.substring(0,8)}-${raw.substring(8,12)}-${raw.substring(12,16)}-${raw.substring(16,20)}-${raw.substring(20)}','handoffId':handoffId,'verifier':_handoffRandom(32),'oldTokenHash':_handoffHash(_token??'')};}
    if(generation!=_epoch)throw StateError('Session changed');
    if(p['handoffId']!=handoffId)throw StateError('Cancel existing handoff first');
    await _saveHandoff(p);
    if(generation!=_epoch||p['oldTokenHash']!=_handoffHash(_token??''))throw StateError('Session changed');
    return _handoff('claim',{'claimId':p['claimId'],'handoffId':handoffId,'challenge':_handoffHash(p['verifier'] as String)},hasSession);
  }
  Future<JsonMap> appHandoffStatus() async {final p=await _pendingHandoff();if(p==null)throw StateError('No pending handoff');return _handoff('status',_handoffBody(p));}
  Future<void> cancelAppHandoff() async {final p=await _pendingHandoff();if(p==null)return;await _handoff('cancel',_handoffBody(p));await _saveHandoff(null);}
  Future<JsonMap> completeAppHandoff({required bool switchConfirmed}) async {
    await _ready;await _writes;if(!switchConfirmed)throw StateError('Explicit switch confirmation required');
    final p=await _pendingHandoff();if(p==null)throw StateError('No pending handoff');
    final current=_handoffHash(_token??''),generation=_epoch;
    if(current!=p['oldTokenHash']&&current!=p['newTokenHash'])throw StateError('Session changed; start a new handoff');
    final body={..._handoffBody(p),'switchConfirmed':true};
    final state=await _handoff('status',body);
    if(['acknowledged','delivered','recovery_expired'].contains(state['status'])&&current==p['newTokenHash']){final account=await getAccount();if(account['userId']!=p['newUserId'])throw StateError('Handoff account mismatch');tracker.updateRuntimeUser(account['userId'] as String);if(state['status']!='acknowledged')await _handoff('ack',body,true);await _saveHandoff(null);return account;}
    final login=await _handoff('redeem',body);final credential=login['accessToken'];
    if(credential is! String||credential.isEmpty||login['userId'] is! String)throw StateError('Invalid handoff session');
    p['newTokenHash']=_handoffHash(credential);p['newUserId']=login['userId'];await _saveHandoff(p);
    if(generation!=_epoch)throw StateError('Session changed');
    final persist=_writes.then((_) async {
      if(generation!=_epoch)throw StateError('Session changed before persistence');
      await _sessionStorage.write(_sessionKey,credential);
    });
    _writes=persist.then<void>((_) {},onError:(Object _,StackTrace __) {});
    await persist;
    if(generation!=_epoch)throw StateError('Session changed during persistence');
    _token=credential;_epoch++;_sequence++;sessionStorageError=null;
    tracker.setRuntimeContext(null,{'user_id':'','ab_snapshot':'{}','config_version':''});try{onSessionChanged?.call();}catch(_){}
    final account=await getAccount();if(account['userId']!=login['userId'])throw StateError('Handoff account mismatch');
    tracker.updateRuntimeUser(login['userId'] as String);
    await _handoff('ack',body,true);await _saveHandoff(null);return login;
  }
  Future<JsonMap> reportAppHandoff(String eventType,{String? handoffId,String? eventId}) {
    final raw=_handoffRandom(16);final id=eventId??'${raw.substring(0,8)}-${raw.substring(8,12)}-${raw.substring(12,16)}-${raw.substring(16,20)}-${raw.substring(20)}';
    return _handoff('event',{'eventType':eventType,'handoffId':handoffId??'','eventId':id});
  }
  Future<JsonMap> loginOrBindIdentity(JsonMap proof) async {
    final requestEpoch=_epoch;
    final login=await _post('/api/v1/client/accounts/login-or-bind',_accountBody(proof));
    if(requestEpoch!=_epoch)throw StateError('Session changed; discarded response');
    _validateGuestRestoreMode(login);
    final token=login['accessToken'],user=login['userId'],action=login['action'];
    if(token is! String || token.trim().isEmpty || user is! String || user.isEmpty || !['guest_upgraded','existing_account_login',if(guestRestoreMode!=null)'account_reauthenticated'].contains(action) || login['accountSwitched'] != (action=='existing_account_login'))throw StateError('Invalid identity resolution');
    final generation=_epoch+1;await setSession(token);
    if(_closed || generation!=_epoch || _token!=token)throw StateError('Session changed; discarded response');
    tracker.setRuntimeContext(user,{'user_id':user,'ab_snapshot':'{}','config_version':''});
    JsonMap? configuration;
    try {configuration=await refresh();}
    catch (_) {if(_closed || generation!=_epoch || _token==null)rethrow;}
    if(_closed || generation!=_epoch)throw StateError('Session changed; discarded response');
    return {...login,'configuration':configuration,'configurationRefreshRequired':configuration==null};
  }
  Future<JsonMap> bindIdentity(JsonMap proof)=>_changeAccount('bind',proof);
  Future<JsonMap> replaceIdentity(JsonMap previous,JsonMap replacement)=>_changeAccount('replace',{'previous':_accountBody(previous),'replacement':_accountBody(replacement)});
  Future<JsonMap> unbindIdentity(JsonMap proof)=>_changeAccount('unbind',proof);
  Future<JsonMap> renewSession()=>_renewal ??= _changeAccount('session/refresh',{}).catchError((Object error){if(error is MpAccountDeletedRecovery&&!_closed&&error.epoch==_epoch)return error.configuration;throw error;}).whenComplete(() { _renewal=null; });
  Future<JsonMap> renewSessionForBusiness(String connectionId) async {
    await renewSession();return businessTicket(connectionId);
  }
  Future<JsonMap> loginBusiness(String connectionId,Future<JsonMap> Function(String ticket) exchangeTicket) async {
    final generation=_epoch;
    final payload=await businessTicket(connectionId);
    if(_closed||generation!=_epoch)throw StateError('Session changed; discarded business ticket');
    final ticket=payload['ticket'];if(ticket is! String || ticket.trim().isEmpty)throw StateError('Missing ticket');
    final result=await exchangeTicket(ticket);
    if(_closed||generation!=_epoch)throw StateError('Session changed; discarded business response');
    return result;
  }
  Future<JsonMap> logout({bool allDevices=false})=>_changeAccount('logout${allDevices?'?allDevices=true':''}',{});
  Future<JsonMap> getSessions()=>_post('/api/v1/client/accounts/sessions',{});
  Future<JsonMap> revokeSession(String id)=>_post('/api/v1/client/accounts/sessions/revoke',{'sessionId':id});
  Future<JsonMap> businessTicket(String id)=>_post('/api/v1/client/accounts/business-ticket',{'connectionId':id});
  Future<JsonMap> resetPassword(JsonMap proof)=>_post('/api/v1/client/accounts/password/reset',_accountBody(proof),authenticated:false);
  Future<JsonMap> deletionPrecheck()=>_post('/api/v1/client/accounts/deletion/precheck',{});
  Future<JsonMap> deleteAccount(JsonMap proof) async {
    final generation=_epoch;final result=await _post('/api/v1/client/accounts/deletion',_accountBody(proof));if(generation!=_epoch)throw StateError('Session changed; discarded response');await clearLocalSession();return result;
  }
  Future<JsonMap> deletionStatus(JsonMap receipt)=>_post('/api/v1/client/accounts/deletion/status',receipt,authenticated:false);
  Future<JsonMap> getUserInfo() async {await _ready;if(autoGuestLogin&&!_autoStartupCancelled&&_token==null&&(_guestLogin!=null||_autoGuestEligible))return Map<String,Object?>.from((await loginGuest())['user'] as Map);try{return await _post('/api/v1/client/runtime/user',_context);}on MpAccountDeletedRecovery catch(e){if(_closed||e.epoch!=_epoch)rethrow;return Map<String,Object?>.from(e.configuration['user'] as Map);}}
  Future<JsonMap> refresh() async {
    await _ready;if(autoGuestLogin&&!_autoStartupCancelled&&_token==null&&(_guestLogin!=null||_autoGuestEligible))return loginGuest();
    final request=++_sequence;
    final JsonMap value;
    try{value=await _post('/api/v1/client/runtime/config',_context);}on MpAccountDeletedRecovery catch(e){if(_closed||e.epoch!=_epoch||e.sequence!=_sequence)rethrow;return e.configuration;}
    if(request!=_sequence)throw StateError('Superseded response');
    final user=value['user'] as Map;
    tracker.setRuntimeContext(user['userId'] as String,{'user_id':user['userId'],'ab_snapshot':jsonEncode(value['experiments']??{}),'config_version':value['configVersion']});
    return value;
  }
  void close(){if(_closed)return;tracker.cancelStartupIdentity();try { onSessionChanged?.call(); } catch (_) {}_closed=true;_epoch++;_sequence++;_token=null;tracker.setRuntimeContext(null,{'user_id':'','ab_snapshot':'{}','config_version':''});if(_ownsHttp)_http.close();}
}
