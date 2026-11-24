import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A hint to discard connections tied to a previous route, never an assertion
/// that the configured service is reachable. No addresses or network names cross
/// the platform boundary. Missing plugins are tolerated by the periodic probe.
class NetworkPathChange {
  const NetworkPathChange({required this.available});
  final bool available;
}

abstract interface class NetworkMonitor {
  Stream<NetworkPathChange> get changes;
}

class SystemNetworkMonitor implements NetworkMonitor {
  const SystemNetworkMonitor();
  static const _channel = EventChannel('nearlink/network_path');

  @override
  Stream<NetworkPathChange> get changes {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return const Stream.empty();
    }
    return _channel.receiveBroadcastStream().map((event) {
      if (event is! Map || event['available'] is! bool) {
        throw const FormatException('Invalid network path notification');
      }
      return NetworkPathChange(available: event['available'] as bool);
    });
  }
}
