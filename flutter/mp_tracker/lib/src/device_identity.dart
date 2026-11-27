import 'dart:convert';
import 'core.dart';

/// Separates durable guest identity from the replaceable event queue and Token installation scope.
class DeviceIdentityStorage implements TrackerStorage {
  DeviceIdentityStorage({required this.config, required this.platform, required this.queue,
    required this.readSecure, required this.writeSecure, required this.androidId,
    required this.readScope, required this.writeScope});
  final MpTrackerConfig config;
  final String platform;
  final TrackerStorage queue;
  final Future<String?> Function(String) readSecure;
  final Future<void> Function(String, String) writeSecure;
  final Future<String?> Function() androidId;
  final Future<String?> Function(String) readScope;
  final Future<void> Function(String, String) writeScope;
  String? recoveryId;
  String sessionScope = '';
  @override
  Future<String?> read(String key) async {
    final raw = await queue.read(key);
    if (platform == 'web') return raw;
    final local = raw == null ? null : (jsonDecode(raw) as Map)['deviceId'] as String?;
    final scope = 'mp_device_identity_v1:$platform:${base64Url.encode(utf8.encode(config.appKey))}';
    String? saved;
    if (platform == 'ios') {
      saved = await readSecure(scope); // Propagate locked/unavailable Keychain, never generate a temporary ID.
      if (saved != null && saved.isEmpty) throw StateError('设备标识缓存无效');
    } else {
      final id = await androidId();
      if (id == null || !RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(id) ||
          id.toLowerCase() == '9774d56d682e549c' || id == '0000000000000000') {
        throw StateError('稳定设备标识暂不可用，请重试；未创建新游客');
      }
      recoveryId = 'android:${id.toLowerCase()}';
    }
    final chosen = config.deviceId ?? local ?? saved ?? recoveryId ?? newEventId();
    if (chosen.isEmpty || (local != null && local != chosen) || (saved != null && saved != chosen)) {
      throw StateError('设备标识与已有缓存不一致，停止初始化以免事件或账号混用');
    }
    if (platform == 'ios' && saved == null) {
      await writeSecure(scope, chosen);
      if (await readSecure(scope) != chosen) throw StateError('设备标识保存失败');
    }
    sessionScope = await readScope('$scope:session') ?? (raw == null ? newEventId() : '');
    await writeScope('$scope:session', sessionScope);
    return raw ?? jsonEncode({'deviceId': chosen, 'installed': false, 'events': []});
  }
  @override
  Future<void> write(String key, String value) => queue.write(key, value);
}
