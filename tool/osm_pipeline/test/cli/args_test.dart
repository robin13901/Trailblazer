import 'dart:io';

import 'package:osm_pipeline/cli/args.dart';
import 'package:osm_pipeline/cli/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File pbf;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('osm_pipeline_test_');
    pbf = File(p.join(tmp.path, 'fake.osm.pbf'))..writeAsBytesSync([0]);
  });

  tearDown(() {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  group('ParsedArgs.parse', () {
    test('missing --pbf throws PipelineArgsError mentioning "--pbf required"',
        () {
      expect(
        () => ParsedArgs.parse([]),
        throwsA(
          isA<PipelineArgsError>().having(
            (e) => e.message,
            'message',
            contains('--pbf required'),
          ),
        ),
      );
    });

    test('nonexistent --pbf throws PipelineIoError mentioning "not found"',
        () {
      expect(
        () => ParsedArgs.parse(['--pbf=/does/not/exist.pbf']),
        throwsA(
          isA<PipelineIoError>().having(
            (e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
    });

    test('--bbox with three fields throws mentioning "four comma-separated"',
        () {
      expect(
        () => ParsedArgs.parse(['--pbf=${pbf.path}', '--bbox=1,2,3']),
        throwsA(
          isA<PipelineArgsError>().having(
            (e) => e.message,
            'message',
            contains('four comma-separated'),
          ),
        ),
      );
    });

    test('--bbox with out-of-range longitude throws mentioning "longitude"',
        () {
      expect(
        () =>
            ParsedArgs.parse(['--pbf=${pbf.path}', '--bbox=200,50,210,55']),
        throwsA(
          isA<PipelineArgsError>().having(
            (e) => e.message,
            'message',
            contains('longitude'),
          ),
        ),
      );
    });

    test('valid --pbf and Berlin --bbox parses cleanly', () {
      final args = ParsedArgs.parse(
        ['--pbf=${pbf.path}', '--bbox=13.0,52.3,13.8,52.7'],
      );
      expect(args.pbfPath, pbf.path);
      expect(args.bbox, isNotNull);
      expect(args.bbox!.minLng, 13.0);
      expect(args.bbox!.minLat, 52.3);
      expect(args.bbox!.maxLng, 13.8);
      expect(args.bbox!.maxLat, 52.7);
    });

    test('valid --pbf, no --bbox → bbox is null', () {
      final args = ParsedArgs.parse(['--pbf=${pbf.path}']);
      expect(args.pbfPath, pbf.path);
      expect(args.bbox, isNull);
    });

    test('--bbox with non-numeric field throws PipelineArgsError', () {
      expect(
        () =>
            ParsedArgs.parse(['--pbf=${pbf.path}', '--bbox=a,b,c,d']),
        throwsA(isA<PipelineArgsError>()),
      );
    });

    test('--bbox with minLng >= maxLng throws PipelineArgsError', () {
      expect(
        () => ParsedArgs.parse(
          ['--pbf=${pbf.path}', '--bbox=13.8,52.3,13.0,52.7'],
        ),
        throwsA(
          isA<PipelineArgsError>().having(
            (e) => e.message,
            'message',
            contains('minLng'),
          ),
        ),
      );
    });

    test('--bbox with minLat >= maxLat throws PipelineArgsError', () {
      expect(
        () => ParsedArgs.parse(
          ['--pbf=${pbf.path}', '--bbox=13.0,52.7,13.8,52.3'],
        ),
        throwsA(
          isA<PipelineArgsError>().having(
            (e) => e.message,
            'message',
            contains('minLat'),
          ),
        ),
      );
    });
  });
}
