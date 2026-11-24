import 'package:flutter_test/flutter_test.dart';
import 'package:nearlink/core/group_presence.dart';

Map<String, dynamic> snapshot(int count, int observed, {int ttl = 90000}) => {
  'onlineCount': count,
  'presenceTtlMs': ttl,
  'presenceObservedAt': observed,
};

void main() {
  test(
    'presence is a monotonic bounded lease; network time cannot extend it',
    () {
      var elapsed = 1000;
      final cache = GroupPresence(elapsedMilliseconds: () => elapsed);
      addTearDown(cache.dispose);
      var changes = 0;
      cache.onChanged = () => changes++;
      cache.accept({'room': snapshot(5, 100)}, requestStartedAt: 0);
      expect(cache.countFor('room'), 5);
      elapsed = 89999;
      expect(cache.countFor('room'), 5);
      elapsed = 90000;
      expect(cache.countFor('room'), isNull);
      final before = changes;
      cache.expire();
      expect(changes, before + 1);
      cache.accept({
        'room': snapshot(2, 200, ttl: 999999),
      }, requestStartedAt: elapsed);
      elapsed += 90000;
      expect(cache.countFor('room'), isNull);
    },
  );

  test(
    'replayed observations never renew and old-server fields stay unknown',
    () {
      var elapsed = 0;
      final cache = GroupPresence(elapsedMilliseconds: () => elapsed);
      addTearDown(cache.dispose);
      cache.accept({'room': snapshot(4, 100)}, requestStartedAt: 0);
      elapsed = 80000;
      cache.accept({'room': snapshot(1, 99)}, requestStartedAt: elapsed);
      expect(cache.countFor('room'), 4);
      cache.accept({'room': snapshot(1, 100)}, requestStartedAt: elapsed);
      elapsed = 90000;
      expect(cache.countFor('room'), isNull);
      cache.accept({'room': snapshot(0, 101)}, requestStartedAt: elapsed);
      expect(cache.countFor('room'), 0);
      cache.accept({'room': {}}, requestStartedAt: elapsed);
      expect(cache.countFor('room'), isNull);
      cache.accept({'room': snapshot(51, 102)}, requestStartedAt: elapsed);
      expect(cache.countFor('room'), isNull);
      cache.accept({'room': snapshot(1, 103)}, requestStartedAt: elapsed);
      cache.remove('room');
      expect(cache.countFor('room'), isNull);
    },
  );
}
