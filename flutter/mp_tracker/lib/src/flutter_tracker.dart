import 'dart:async';
import 'dart:convert';

import 'package:android_id/android_id.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core.dart';
import 'device_identity.dart';
import 'startup_performance.dart';

class PreferencesTrackerStorage implements TrackerStorage {
  PreferencesTrackerStorage(this.preferences);
  final SharedPreferences preferences;
  @override
  Future<String?> read(String key) async => preferences.getString(key);
  @override
  Future<void> write(String key, String value) async {
    if (!await preferences.setString(key, value)) {
      throw StateError('埋点缓存保存失败');
    }
  }
}

class HttpTrackerTransport implements AuthenticatedTrackerTransport {
  HttpTrackerTransport({
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  String? Function()? _collectionTokenProvider;
  @override
  void setCollectionTokenProvider(String? Function()? provider) => _collectionTokenProvider = provider;
  @override
  Future<bool> send(Uri uri, String platformHeader, JsonMap payload) async {
    String? token;
    try { token = _collectionTokenProvider?.call(); } catch (_) { /* Keep anonymous collection available. */ }
    final response = await _client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'X-Platform': platformHeader,
            if (token != null && token.trim().isNotEmpty && !token.contains(RegExp(r'[\r\n]')))
              'Authorization': 'Bearer $token',
          },
          body: jsonEncode(payload),
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) return false;
    final body = jsonDecode(response.body);
    return body is Map &&
        body['code'] == 0 &&
        body['data'] is Map &&
        body['data']['accepted'] == (payload['events'] as List).length;
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Initialize once in the main isolate after privacy consent, before runApp.
class MpTracker with WidgetsBindingObserver {
  MpTracker._(this._core, this._networkSubscription, this._observeLifecycle, {required this.versionCode, this.recoveryId, this.sessionScope = ''});
  final int? versionCode;
  final String? recoveryId;
  final String sessionScope;
  final TrackerCore _core;
  final StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  final bool _observeLifecycle;
  bool _disposed = false;
  static Future<MpTracker> initialize(MpTrackerConfig config) => SdkPerformance(onTiming: config.onTiming).measure('initialize.total', () => _initialize(config));
  static Future<MpTracker> _initialize(MpTrackerConfig config) async {
    WidgetsFlutterBinding.ensureInitialized();
    final platform =
        kIsWeb
            ? 'web'
            : switch (defaultTargetPlatform) {
              TargetPlatform.iOS => 'ios',
              TargetPlatform.android => 'android',
              _ => throw UnsupportedError('目前仅支持 iOS、Android 和 Web'),
            };
    final environment = <String, Object?>{};
    void warn(Object e, StackTrace s) {
      try {
        config.onError?.call(e, s);
      } catch (_) {
        /* Logging is optional. */
      }
    }

    final performance = SdkPerformance(onTiming: config.onTiming, onError: warn);
    // Start independent platform calls together. Optional data never changes identity.
    final preferencesFuture = performance.measure('initialize.preferences', () => SharedPreferences.getInstance().timeout(const Duration(seconds: 5)));
    // Observe early failures even while package info is pending; await the original future below.
    unawaited(preferencesFuture.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    final packageFuture = performance.optional<PackageInfo?>('initialize.package_info', () => PackageInfo.fromPlatform(), null, timeout: const Duration(seconds: 5));
    final deviceFuture = performance.optional<Map<String,Object?>>('initialize.device_info', () async {
      final info = DeviceInfoPlugin();
      if (platform == 'android') {
        final device = await info.androidInfo;
        return {'os_version':device.version.release,'device_brand':device.brand,'device_model':device.model};
      }
      if (platform == 'ios') {
        final device = await info.iosInfo;
        return {'os_version':device.systemVersion,'device_brand':'Apple','device_model':device.utsname.machine,'device_type':device.model.toLowerCase().contains('ipad')?'tablet':'phone'};
      }
      final device = await info.webBrowserInfo;
      return {if(device.platform!=null)'os_version':device.platform,'device_brand':device.browserName.name};
    }, {});
    final connectivity = Connectivity();
    final networkFuture = performance.optional<List<ConnectivityResult>?>('initialize.network', () => connectivity.checkConnectivity(), null);
    final package = await packageFuture;
    if (package != null) {
      environment['app_version'] = package.version;
      environment['app_build'] = package.buildNumber;
      if (package.buildNumber.isNotEmpty) environment['app_version_code'] = package.buildNumber;
    }
    final detectedBuild = environment['app_version_code']?.toString();
    final configuredBuild = config.appVersionCode;
    int? parseBuild(String? raw) {
      if (raw == null) return null;
      final value = int.tryParse(raw);
      if (!RegExp(r'^[0-9]{1,10}$').hasMatch(raw) || value == null || value > 2147483647) {
        throw ArgumentError('Build code must be an integer between 0 and 2147483647');
      }
      return value;
    }
    final detectedCode = parseBuild(detectedBuild);
    final configuredCode = parseBuild(configuredBuild);
    if (detectedCode != null && configuredCode != null && detectedCode != configuredCode) {
      throw ArgumentError('appVersionCode differs from package buildNumber');
    }
    final versionCode = detectedCode ?? configuredCode;
    if (platform != 'web' && detectedCode == null) throw StateError('Package buildNumber unavailable');
    String? network;
    String networkName(List<ConnectivityResult> results) {
      for (final pair
          in {
            ConnectivityResult.wifi: 'wifi',
            ConnectivityResult.ethernet: 'ethernet',
            ConnectivityResult.mobile: 'cellular',
            ConnectivityResult.vpn: 'vpn',
            ConnectivityResult.bluetooth: 'bluetooth',
          }.entries) {
        if (results.contains(pair.key)) return pair.value;
      }
      return results.contains(ConnectivityResult.none) ? 'none' : 'unknown';
    }

    StreamSubscription<List<ConnectivityResult>>? subscription;
    try {
      final preferences = await preferencesFuture;
      environment.addAll(await deviceFuture);
      final networks = await networkFuture;
      if (networks != null) network = networkName(networks);
      try {
        subscription = connectivity.onConnectivityChanged.listen((values) {
          network = networkName(values);
        }, onError: warn);
      } catch (e, s) { warn(e, s); }
      const secure = FlutterSecureStorage(iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device));
      final identity = DeviceIdentityStorage(config: config, platform: platform, queue: PreferencesTrackerStorage(preferences),
        readSecure: (key) => performance.measure('initialize.identity_read', () => secure.read(key: key).timeout(const Duration(seconds: 5))), writeSecure: (key, value) => secure.write(key: key, value: value),
        androidId: () => performance.measure('initialize.identity_read', () => const AndroidId().getId().timeout(const Duration(seconds: 5))), readScope: (key) async => preferences.getString(key),
        writeScope: (key, value) async { if (!await preferences.setString(key, value)) throw StateError('设备标识保存失败'); });
      final core = await performance.measure('initialize.identity_queue', () => TrackerCore.open(
        config: config,
        platform: platform,
        storage: identity,
        transport: HttpTrackerTransport(timeout: config.requestTimeout),
        environment: () {
          final dispatcher = WidgetsBinding.instance.platformDispatcher;
          final locale = dispatcher.locale;
          final view = dispatcher.views.firstOrNull;
          return {
            ...environment,
            'device_language': locale.toLanguageTag(),
            if (locale.countryCode != null) 'device_region': locale.countryCode,
            if (view != null)
              'screen_resolution':
                  '${view.physicalSize.width.round()}x${view.physicalSize.height.round()}',
            if (platform == 'android' && view != null)
              'device_type':
                  view.physicalSize.shortestSide / view.devicePixelRatio >= 600
                      ? 'tablet'
                      : 'phone',
            if (network != null) 'network_type': network,
          };
        },
      ));
      final tracker = MpTracker._(
        core,
        subscription,
        config.automaticLifecycle,
        versionCode: versionCode, recoveryId: identity.recoveryId, sessionScope: identity.sessionScope,
      );
      if (config.automaticLifecycle) {
        WidgetsBinding.instance.addObserver(tracker);
      }
      return tracker;
    } catch (_) {
      await subscription?.cancel();
      rethrow;
    }
  }

  Future<T> measureOperation<T>(String stage, Future<T> Function() action) => SdkPerformance(onTiming: _core.config.onTiming).measure(stage, action);
  String get deviceId => _core.deviceId;
  JsonMap get webIdentityContext => _core.webIdentityContext;
  int get clientPlatform => {'ios':1,'android':2,'web':3}[_core.platform]!;
  void cancelStartupIdentity() => _core.cancelStartupIdentity();
  void setRuntimeContext(String? userId, JsonMap fields) => _core.setRuntimeContext(userId,fields);
  void updateRuntimeUser(String userId) => _core.updateRuntimeUser(userId);
  String get collectionEndpoint => _core.config.endpoint.replaceFirst(RegExp(r'/+$'), '');
  void setCollectionTokenProvider(String? Function()? provider) => _core.setCollectionTokenProvider(provider);
  int get pendingCount => _core.pendingCount;
  AdImpression beginAdImpression({required String inventoryId, required String adNetwork, required String adUnitId, String? impressionId}) => _core.beginAdImpression(inventoryId: inventoryId, adNetwork: adNetwork, adUnitId: adUnitId, impressionId: impressionId);
  Future<void> reportAdRevenue(AdImpression impression, {required String value, required String unit, required String currency, String precision = 'estimated'}) => _core.reportAdRevenue(impression, value: value, unit: unit, currency: currency, precision: precision);

  Future<void> track(
    String eventName, {
    JsonMap params = const {},
    String? description,
  }) => _core.track(eventName, params: params, description: description);
  void setCommonFields(JsonMap fields) => _core.setCommonFields(fields);
  Map<String, String> get ruleContext => _core.ruleContext;
  void setRuleContext(JsonMap fields) => _core.setRuleContext(fields);

  /// null/empty clears login identity; it does not change installation identity.
  void setUserId(String? userId) => _core.setUserId(userId);
  Future<void> pageView(String pageName, {String? pageUrl}) {
    if (pageName.trim().isEmpty) throw ArgumentError('页面名称不能为空');
    return track(
      'page_view',
      params: {'page_name': pageName, if (pageUrl != null) 'page_url': pageUrl},
    );
  }

  Future<bool> flush() => _core.flush();
  MpNavigatorObserver navigatorObserver() => MpNavigatorObserver(this);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    // inactive can be a permission dialog; only hidden/paused means background.
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _core.runAutomatic(_core.enterBackground);
    } else if (state == AppLifecycleState.resumed) {
      _core.runAutomatic(_core.enterForeground);
    }
  }

  Future<void> dispose({bool flushPending = true}) async {
    if (_disposed) return;
    _disposed = true;
    if (_observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    await _networkSubscription?.cancel();
    await _core.close(flushPending: flushPending);
  }
}

/// Use named PageRoutes; dialogs are not counted as screen views.
class MpNavigatorObserver extends NavigatorObserver {
  MpNavigatorObserver(MpTracker tracker)
    : _record = ((name) {
        if (!tracker._disposed) {
          tracker._core.runAutomatic(() => tracker.pageView(name));
        }
      });
  @visibleForTesting
  MpNavigatorObserver.forTesting(this._record);
  final void Function(String pageName) _record;
  void _view(Route<dynamic>? route) {
    if (route is! PageRoute || route.settings.name?.isNotEmpty != true) {
      return;
    }
    _record(route.settings.name!);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _view(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _view(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _view(newRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isCurrent == true) _view(previousRoute);
  }
}
