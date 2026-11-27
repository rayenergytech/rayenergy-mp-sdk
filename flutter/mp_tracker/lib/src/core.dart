import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'rule_context.dart';
import 'sdk_version.dart';

typedef JsonMap = Map<String, Object?>;

/// An immutable, APP-scoped snapshot of a real ad impression.
class AdImpression {
  AdImpression._(this._appKey, this._event, this._fields);
  final String _appKey;
  final JsonMap _event;
  final JsonMap _fields;
}

/// A storage key is scoped to endpoint + APP key + actual client platform.
abstract interface class TrackerStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

abstract interface class TrackerTransport {
  /// True only for HTTP success, code=0, and accepted=the full batch length.
  Future<bool> send(Uri uri, String platformHeader, JsonMap payload);
  void close();
}

/// Optional extension; existing custom transports remain compatible and anonymous.
abstract interface class AuthenticatedTrackerTransport implements TrackerTransport {
  void setCollectionTokenProvider(String? Function()? provider);
}

class MpTrackerConfig {
  MpTrackerConfig({
    required this.appKey,
    required this.endpoint,
    this.maxBatchSize = 100,
    this.maxQueueSize = 10000,
    this.flushInterval = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 10),
    this.commonFields = const {},
    this.appVersion,
    this.appVersionCode,
    this.deviceId,
    this.installationAlreadyTracked = false,
    this.automaticLifecycle = true,
    this.onError,
    this.onTiming,
  }) {
    final uri = Uri.tryParse(endpoint);
    if ((deviceId != null && deviceId!.trim().isEmpty) ||
        (installationAlreadyTracked && deviceId == null)) {
      throw ArgumentError('迁移安装记录时必须提供原 SDK 的真实 deviceId');
    }
    if (appKey.trim().isEmpty ||
        uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError('appKey 必填；endpoint 必须为无凭据、查询参数的 HTTP(S) 网关地址');
    }
    if (maxBatchSize < 1 ||
        maxBatchSize > 100 ||
        maxQueueSize < maxBatchSize ||
        maxQueueSize < 2 ||
        flushInterval <= Duration.zero ||
        requestTimeout <= Duration.zero) {
      throw ArgumentError('单批需为1~100条，缓存至少容纳一批和2条基础事件，时间必须为正');
    }
  }
  final String appKey, endpoint;
  final int maxBatchSize, maxQueueSize;
  final Duration flushInterval, requestTimeout;
  final JsonMap commonFields;
  final String? appVersion, appVersionCode;

  /// Optional stable ID supplied by the host APP, or migration of the previous installation ID.
  final String? deviceId;
  final bool installationAlreadyTracked;
  final bool automaticLifecycle;

  /// Automatic tracking failures are reported here without failing the app UI.
  final void Function(Object error, StackTrace stack)? onError;

  /// Optional local diagnostics; stage, elapsed milliseconds, success. No automatic upload.
  final void Function(String stage, int elapsedMs, bool success)? onTiming;
}

String newEventId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Transport-independent queue engine; one instance per scope in one isolate.
class TrackerCore {
  TrackerCore._(
    this.config,
    this.platform,
    this.storage,
    this.transport,
    this.environment,
    this.clock,
    this.storageKey,
  );
  final MpTrackerConfig config;
  final String platform, storageKey;
  final TrackerStorage storage;
  final TrackerTransport transport;
  void setCollectionTokenProvider(String? Function()? provider) {
    if (transport is AuthenticatedTrackerTransport) {
      (transport as AuthenticatedTrackerTransport).setCollectionTokenProvider(provider);
    }
  }
  final JsonMap Function() environment;
  final DateTime Function() clock;
  final List<JsonMap> _queue = [];
  final Set<String> _paramNames = {};
  JsonMap _common = {};
  final RuleContext _ruleContext = RuleContext();
  Map<String, String> get ruleContext => _ruleContext.snapshot(eventFields: environment());
  JsonMap get webIdentityContext {
    if (platform != 'web') return {};
    final values = {..._common, ...environment()};
    return {
      for (final key in ['os_version','device_model','screen_resolution','device_language'])
        if (values[key] is String) key: values[key],
      if (ruleContext['language'] != null) 'device_language': ruleContext['language'],
      'timezone_offset': clock().timeZoneOffset.inMinutes,
    };
  }
  void setRuleContext(JsonMap fields) {
    _checkOpen();
    _ruleContext.patch(fields);
  }
  Set<String>? _startupIds = {};
  DateTime? _startupDeadline;
  void cancelStartupIdentity() { _startupIds = null; }
  JsonMap _runtimeFields = {};
  void setRuntimeContext(String? userId, JsonMap fields) { setUserId(userId); _runtimeFields = Map.of(fields); }
  void updateRuntimeUser(String userId) { setUserId(userId); _runtimeFields['user_id']=userId; }
  String deviceId = '', _session = newEventId();
  String? _userId;
  int _index = 0, _failures = 0;
  bool _installed = false, _closed = false, _closing = false;
  bool _background = false;
  DateTime? _retryAfter;
  Future<void> _serial = Future.value();
  Future<bool>? _sending;
  Timer? _timer;
  static final Set<String> _activeScopes = {};
  static const sdkFields = {
    'event_id',
    'event_name',
    'event_description',
    'event_desc',
    'event_time',
    'session_id',
    'event_index',
    'adgroup',
    'creative',
    'app_key',
    'app_version',
    'app_build',
    'app_version_code',
    'channel',
    'platform',
    'os_version',
    'device_brand',
    'device_model',
    'device_type',
    'screen_resolution',
    'device_language',
    'timezone_offset',
    'user_id',
    'device_id',
    'idfv',
    'idfa',
    'gaid',
    'network_type',
    'carrier',
    'country_code',
    'ip',
    'att_status',
    'consent_flags',
    'is_lat',
    'ab_snapshot',
    'sdk_version',
    'is_background',
    'sdk_platform',
    'report_source',
    'common_fields',
    'params',
  };
  static const _owned = {
    'event_id',
    'event_name',
    'event_description',
    'event_desc',
    'event_time',
    'session_id',
    'event_index',
    'adgroup',
    'creative',
    'app_key',
    'app_version',
    'app_build',
    'app_version_code',
    'platform',
    'user_id',
    'device_id',
    'sdk_version',
    'sdk_platform',
    'report_source',
    'is_background',
    'common_fields',
    'params',
    'os_version',
    'device_brand',
    'device_model',
    'device_type',
    'screen_resolution',
    'device_language',
    'timezone_offset',
    'network_type',
    'device_region',
  };

  static Future<TrackerCore> open({
    required MpTrackerConfig config,
    required String platform,
    required TrackerStorage storage,
    required TrackerTransport transport,
    required JsonMap Function() environment,
    DateTime Function()? clock,
    bool startTimer = true,
  }) async {
    if (!['ios', 'android', 'web'].contains(platform)) {
      throw ArgumentError('Flutter SDK 仅支持 iOS、Android 和 Web');
    }
    final endpoint = config.endpoint.replaceAll(RegExp(r'/+$'), '');
    final key =
        'mp_tracker_v1_${base64Url.encode(utf8.encode('$endpoint|${config.appKey}|$platform'))}';
    if (!_activeScopes.add(key)) {
      transport.close();
      throw StateError('同一 APP 和端只能初始化一个埋点实例');
    }
    final core = TrackerCore._(
      config,
      platform,
      storage,
      transport,
      environment,
      clock ?? DateTime.now,
      key,
    );
    try {
      core._startupDeadline = core.clock().add(const Duration(seconds: 60));
      core.setCommonFields(config.commonFields);
      final raw = await storage.read(key);
      if (raw != null) {
        final state = jsonDecode(raw) as Map<String, dynamic>;
        core.deviceId = state['deviceId'] as String;
        if (config.deviceId != null && config.deviceId != core.deviceId) {
          throw StateError('不能修改已有缓存的安装ID，避免历史事件混报');
        }
        core._installed = state['installed'] == true;
        core._queue.addAll(
          (state['events'] as List).map(
            (e) => Map<String, Object?>.from(e as Map),
          ),
        );
        if (core.deviceId.isEmpty || core._queue.length > config.maxQueueSize) {
          throw StateError('历史缓存无效或超过缓存上限，不自动删除');
        }
        for (final event in core._queue) {
          core._paramNames.addAll(
            (event['params'] as Map).keys.map(
              (k) => k.toString().toLowerCase(),
            ),
          );
        }
        core.setCommonFields(config.commonFields);
      } else {
        core.deviceId = config.deviceId ?? newEventId();
        core._installed = config.installationAlreadyTracked;
      }
      if (config.automaticLifecycle) {
        // Installation marker and its event are saved in the same snapshot.
        await core._locked(() async {
          final events = <JsonMap>[];
          if (!core._installed) events.add(core._event('app_install', {}));
          events.add(core._event('app_launch', {}));
          if (core._queue.length + events.length > config.maxQueueSize) {
            // A full offline queue must still be openable so it can be sent.
            core.reportError(
              StateError('缓存已满，本次启动事件未保存，历史事件保留待重传'),
              StackTrace.current,
            );
            return;
          }
          await core._save([...core._queue, ...events], installed: true);
          core._queue.addAll(events);
          core._installed = true;
        });
      } else {
        await core._save(core._queue);
      }
      if (startTimer) {
        core._timer = Timer.periodic(
          config.flushInterval,
          (_) => core.runAutomatic(() => core.flush(automatic: true)),
        );
      }
      return core;
    } catch (_) {
      _activeScopes.remove(key);
      transport.close();
      rethrow;
    }
  }

  int get pendingCount => _queue.length;
  int get effectiveBatchSize => platform == 'web' ? min(50, config.maxBatchSize) : config.maxBatchSize;
  void _checkOpen() {
    if (_closed || _closing) throw StateError('埋点实例已关闭');
  }

  void setUserId(String? id) {
    _checkOpen();
    _userId = id?.trim();
    final user = _userId;
    if (user != null && user.isNotEmpty && _startupIds != null) {
      final ids = Set<String>.of(_startupIds!);
      final timely = _startupDeadline != null && clock().isBefore(_startupDeadline!);
      _startupIds = null;
      // Queue the durable rewrite before any drain; preserve event IDs, order and times.
      runAutomatic(() => _locked<void>(() async {
        if (!timely) return;
        final events = _queue.map((event) {
          if (!ids.contains(event['event_id'])) return event;
          final fields = Map<String, Object?>.from(event['common_fields'] as Map);
          if ((fields['user_id']?.toString() ?? '').isNotEmpty) return event;
          fields['user_id'] = user;
          return {...event, 'user_id': user, 'common_fields': fields};
        }).toList();
        await _save(events);
        _queue..clear()..addAll(events);
      }));
    }
  }

  void setCommonFields(JsonMap fields) {
    _checkOpen();
    final common = Map<String, Object?>.of(fields)..removeWhere((key, _) => RuleContext.eventKeys.values.contains(key));
    for (final name in common.keys) {
      _validateName(name);
      if (_owned.contains(name.toLowerCase()) ||
          _paramNames.contains(name.toLowerCase())) {
        throw ArgumentError('公共字段 $name 与 SDK 保留字段或事件属性冲突');
      }
    }
    _ruleContext.replaceCommon(fields);
    _common = _copy(common);
  }

  Future<void> track(
    String name, {
    JsonMap params = const {},
    String? description,
  }) {
    _checkOpen();
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$').hasMatch(name)) {
      throw ArgumentError('事件名必须为1~64位字母、数字或下划线，不能以数字开头');
    }
    final copied = _copy(params);
    for (final key in copied.keys) {
      _validateName(key);
      if (sdkFields.contains(key.toLowerCase()) ||
          _common.keys.any((k) => k.toLowerCase() == key.toLowerCase()) ||
          environment().keys.any((k) => k.toLowerCase() == key.toLowerCase())) {
        throw ArgumentError('事件属性 $key 与公共字段冲突');
      }
    }
    // Capture identity, fields and time at the call site, not at send time.
    final event = _event(name, copied, description: description);
    _paramNames.addAll(copied.keys.map((k) => k.toLowerCase()));
    return _locked(() async {
      if (_queue.length >= config.maxQueueSize) {
        throw StateError('埋点缓存已满，未丢弃历史事件');
      }
      await _save([..._queue, event]);
      _queue.add(event);
      if (_queue.length >= effectiveBatchSize) {
        runAutomatic(() => flush(automatic: true));
      }
    });
  }

  AdImpression beginAdImpression({required String inventoryId, required String adNetwork, required String adUnitId, String? impressionId}) {
    _checkOpen();
    final id = impressionId ?? newEventId();
    for (final s in [inventoryId, adNetwork, adUnitId, id]) {
      if (s.trim().isEmpty || s.length > 128 || s.codeUnits.any((c) => c < 32)) throw ArgumentError('广告曝光标识无效');
    }
    return AdImpression._(config.appKey, _event('ad_impression_revenue', {}), {'ad_inventory_id': inventoryId, 'ad_revenue_network': adNetwork, 'ad_revenue_unit_id': adUnitId, 'ad_impression_id': id});
  }

  Future<void> reportAdRevenue(AdImpression impression, {required String value, required String unit, required String currency, String precision = 'estimated'}) {
    _checkOpen();
    if (impression._appKey != config.appKey || !RegExp(r'^[0-9]{1,12}(\.[0-9]{1,12})?$').hasMatch(value) || !['per_impression','micros','ecpm','bid_cpm'].contains(unit) || !RegExp(r'^[A-Z]{3}$').hasMatch(currency) || !['exact','estimated','publisher_defined','unknown'].contains(precision) || (['ecpm','bid_cpm'].contains(unit) && precision != 'estimated')) throw ArgumentError('广告收入参数无效');
    final fraction = value.contains('.') ? value.split('.')[1].replaceFirst(RegExp(r'0+$'), '') : '';
    if (fraction.length > (unit == 'micros' ? 6 : ['ecpm','bid_cpm'].contains(unit) ? 9 : 12)) throw ArgumentError('广告金额换算后最多12位小数');
    final event = _copy(impression._event);
    event['event_id'] = newEventId();
    event['params'] = {...impression._fields, 'ad_impression_time_ms': event['event_time'], 'ad_revenue_value': value, 'ad_revenue_unit': unit, 'ad_revenue_currency': currency, 'ad_revenue_precision': precision};
    return _locked(() async {
      if (_queue.length >= config.maxQueueSize) throw StateError('埋点缓存已满，未丢弃历史事件');
      await _save([..._queue, event]); _queue.add(event);
      if (_queue.length >= effectiveBatchSize) runAutomatic(() => flush(automatic: true));
    });
  }

  JsonMap _event(String name, JsonMap params, {String? description}) {
    final now = clock();
    final environmentFields = environment();
    final context = _ruleContext.snapshot(eventFields: environmentFields);
    final id = newEventId();
    if (_startupDeadline != null && now.isBefore(_startupDeadline!) && (_userId ?? '').isEmpty && ['app_install','app_launch','page_view'].contains(name)) _startupIds?.add(id);
    return _copy({
      ...environmentFields,
      if (context['country'] != null) 'country_code': context['country'],
      if (context['language'] != null) 'device_language': context['language'],
      if (context['channel'] != null) 'channel': context['channel'],
      'event_id': id,
      'event_name': name,
      if (description != null && description.trim().isNotEmpty)
        'event_description': description.trim(),
      'event_time': now.millisecondsSinceEpoch,
      'app_key': config.appKey,
      'device_id': deviceId,
      'platform': platform,
      'sdk_platform': 'flutter',
      'sdk_version': mpSdkVersion,
      'report_source': 'client',
      'session_id': _session,
      'event_index': ++_index,
      'is_background': _background ? 1 : 0,
      if (_userId != null && _userId!.isNotEmpty) 'user_id': _userId,
      if (config.appVersion != null) 'app_version': config.appVersion,
      if (config.appVersionCode != null)
        'app_version_code': config.appVersionCode,
      'timezone_offset': now.timeZoneOffset.inMinutes,
      'common_fields': {..._common,..._runtimeFields,
        if (context['adGroup'] != null) 'adgroup': context['adGroup'],
        if (context['adCreative'] != null) 'creative': context['adCreative']},
      'params': params,
    });
  }

  Future<void> enterBackground() async {
    _checkOpen();
    if (_background) return;
    _background = true;
    await track('app_exit');
    await flush();
  }

  Future<void> enterForeground() async {
    _checkOpen();
    if (!_background) return;
    _background = false;
    _session = newEventId();
    _index = 0;
    await track('app_launch');
    await flush();
  }

  Future<bool> flush({bool automatic = false}) {
    if (_closed) return Future.value(false);
    if (_sending != null) return _sending!;
    if (automatic && _retryAfter != null && clock().isBefore(_retryAfter!)) {
      return Future.value(false);
    }
    final job = _drain();
    _sending = job;
    return job.whenComplete(() {
      if (identical(_sending, job)) _sending = null;
    });
  }

  Future<bool> _drain() async {
    await _serial;
    if ((_startupIds?.isNotEmpty ?? false) && _queue.any((event) => _startupIds!.contains(event['event_id']))) {
      if (clock().isBefore(_startupDeadline!)) return false;
      _startupIds = null;
    }
    // Bound each flush, even if more events are arriving concurrently.
    final maxBatches = (_queue.length / effectiveBatchSize).ceil();
    for (var i = 0; i < maxBatches; i++) {
      final batch = await _locked(
        () async => _queue.take(effectiveBatchSize).toList(),
      );
      if (batch.isEmpty) break;
      bool ok;
      try {
        ok = await transport.send(
          Uri.parse(
            '${config.endpoint.replaceAll(RegExp(r'/+$'), '')}/api/v1/track/collect',
          ),
          {'ios': '1', 'android': '2', 'web': '3'}[platform]!,
          {
            'appKey': config.appKey,
            'deviceId': deviceId,
            'reportSource': 'client',
            'events': batch,
          },
        );
      } catch (e, stack) {
        reportError(e, stack);
        ok = false;
      }
      if (!ok) {
        _failures = min(_failures + 1, 7);
        _retryAfter = clock().add(
          Duration(seconds: min(1 << (_failures - 1), 60)),
        );
        return false;
      }
      await _locked(() async {
        final ids = batch.map((e) => e['event_id']).toSet();
        final remaining =
            _queue.where((e) => !ids.contains(e['event_id'])).toList();
        // Persist acknowledgement before dropping events in memory.
        await _save(remaining);
        _queue
          ..clear()
          ..addAll(remaining);
      });
      _failures = 0;
      _retryAfter = null;
    }
    return true;
  }

  Future<void> close({bool flushPending = true}) async {
    if (_closed || _closing) return;
    _closing = true;
    _timer?.cancel();
    try {
      await _serial;
      if (_sending != null) await _sending;
      if (flushPending) await flush();
    } finally {
      _closed = true;
      transport.close();
      _activeScopes.remove(storageKey);
    }
  }

  void runAutomatic(Future<Object?> Function() action) {
    unawaited(
      Future.sync(action).catchError((Object e, StackTrace s) {
        reportError(e, s);
        return null;
      }),
    );
  }

  void reportError(Object e, StackTrace s) {
    try {
      config.onError?.call(e, s);
    } catch (_) {
      /* Logging cannot break queue. */
    }
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _serial.then((_) => action());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _save(List<JsonMap> events, {bool? installed}) => storage.write(
    storageKey,
    jsonEncode({
      'deviceId': deviceId,
      'installed': installed ?? _installed,
      'events': events,
    }),
  );
  static JsonMap _copy(JsonMap value) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
  static void _validateName(String name) {
    if (name.trim() != name || name.isEmpty || name.length > 64) {
      throw ArgumentError('字段名不能为空、不能含首尾空格且最多64个字符');
    }
  }
}
