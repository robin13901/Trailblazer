import 'package:auto_explore/core/errors/domain_error.dart';
import 'package:auto_explore/core/errors/result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DomainError.wrap', () {
    test('passes DomainError through unchanged', () {
      const original = DatabaseError('foo');
      expect(DomainError.wrap(original), same(original));
    });

    test('wraps arbitrary throwables as UnknownError', () {
      final wrapped = DomainError.wrap(StateError('boom'));
      expect(wrapped, isA<UnknownError>());
      expect(wrapped.cause, isA<StateError>());
    });
  });

  group('Result', () {
    test('Ok maps via when()', () {
      const r = Ok<int>(42);
      final label = r.when(
        ok: (v) => 'ok:$v',
        err: (e) => 'err:${e.message}',
      );
      expect(label, 'ok:42');
    });

    test('Err maps via when()', () {
      const r = Err<int>(NetworkError('offline'));
      final label = r.when(
        ok: (v) => 'ok:$v',
        err: (e) => 'err:${e.message}',
      );
      expect(label, 'err:offline');
    });
  });
}
