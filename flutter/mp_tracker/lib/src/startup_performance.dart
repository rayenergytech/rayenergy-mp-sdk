import 'dart:async';

/// Local timing only: no credentials, identifiers, payloads or automatic uploads.
class SdkPerformance {
  SdkPerformance({this.onTiming, this.onError});
  final void Function(String stage, int elapsedMs, bool success)? onTiming;
  final void Function(Object error, StackTrace stack)? onError;

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    var success = false;
    try {
      final result = await action();
      success = true;
      return result;
    } finally {
      watch.stop();
      try { onTiming?.call(stage, watch.elapsedMilliseconds, success); } catch (_) {}
    }
  }

  Future<T> optional<T>(String stage, Future<T> Function() action, T fallback,
      {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      return await measure(stage, () => Future<T>.sync(action).timeout(timeout));
    } catch (error, stack) {
      try { onError?.call(error, stack); } catch (_) {}
      return fallback;
    }
  }
}
