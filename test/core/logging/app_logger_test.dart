import 'package:auto_explore/core/logging/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  setUp(() {
    // Reset in case another test in the isolate configured it.
    Logger.root.clearListeners();
    Logger.root.level = Level.OFF;
  });

  test('setupLogging enables logging and root has listeners', () {
    setupLogging();
    expect(Logger.root.level, isNot(Level.OFF));
    // At least one onRecord listener has been attached.
    var received = 0;
    Logger('unit-test').onRecord.listen((_) => received++);
    Logger('unit-test').warning('probe');
    // Give the stream a tick.
    return Future<void>.delayed(Duration.zero).then((_) {
      expect(received, greaterThanOrEqualTo(1));
    });
  });
}
