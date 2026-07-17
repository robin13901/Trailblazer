// Kfz highway-class allowlist parity guard.
//
// Asserts set-equality between the offline pipeline's `kKfzHighwayTags` and
// the runtime matcher's `kfzHighwayClasses` (see
// `lib/features/matching/domain/way_candidate.dart`).
//
// The two constants are in different packages (osm_pipeline vs the Flutter app
// root). The pipeline package cannot import the Flutter app package — the app
// references Flutter itself and uses a different sqlite3 version (^3.0.0 vs
// the pipeline's ^2.4.0). Therefore this test lives inside the pipeline
// sub-package and hard-codes the 14-tag runtime set, with a pointer comment
// to the authoritative runtime file. If a future edit to either set fails this
// test, the CI (dart test inside tool/osm_pipeline/) will catch it.
//
// Decision recorded in 10-03-SUMMARY.md:
//   "Parity test location: tool/osm_pipeline/test/filter/kfz_allowlist_parity_test.dart
//    (dart test) with hard-coded runtime set, because the Flutter app package
//    cannot be imported from the pipeline sub-package."
//
// Run from inside tool/osm_pipeline/:
//   dart test test/filter/kfz_allowlist_parity_test.dart

import 'package:osm_pipeline/filter/highway_class.dart';
import 'package:test/test.dart';

void main() {
  // Authoritative runtime set — SOURCE OF TRUTH:
  // lib/features/matching/domain/way_candidate.dart :: kfzHighwayClasses
  // (14 tags, service EXCLUDED per OSM-02 reconciliation).
  // If that file changes, this test MUST be updated to match.
  const runtimeKfzHighwayClasses = <String>{
    'motorway',
    'motorway_link',
    'trunk',
    'trunk_link',
    'primary',
    'primary_link',
    'secondary',
    'secondary_link',
    'tertiary',
    'tertiary_link',
    'unclassified',
    'residential',
    'living_street',
    'road',
  };

  group('Kfz allowlist parity — pipeline vs runtime', () {
    test('kKfzHighwayTags has exactly 14 tags', () {
      expect(kKfzHighwayTags.length, equals(14));
    });

    test('runtime kfzHighwayClasses has exactly 14 tags', () {
      expect(runtimeKfzHighwayClasses.length, equals(14));
    });

    test('pipeline kKfzHighwayTags == runtime kfzHighwayClasses (set equality)',
        () {
      final onlyInPipeline =
          kKfzHighwayTags.difference(runtimeKfzHighwayClasses);
      final onlyInRuntime =
          runtimeKfzHighwayClasses.difference(kKfzHighwayTags);
      expect(
        onlyInPipeline,
        isEmpty,
        reason: 'Tags in pipeline but not runtime: $onlyInPipeline\n'
            'Update lib/features/matching/domain/way_candidate.dart '
            'kfzHighwayClasses to match.',
      );
      expect(
        onlyInRuntime,
        isEmpty,
        reason: 'Tags in runtime but not pipeline: $onlyInRuntime\n'
            'Update tool/osm_pipeline/lib/filter/highway_class.dart '
            'kKfzHighwayTags to match.',
      );
    });

    test('service is explicitly excluded from both sets', () {
      expect(kKfzHighwayTags, isNot(contains('service')));
      expect(runtimeKfzHighwayClasses, isNot(contains('service')));
    });

    test('all pipeline tags are present in runtime set', () {
      for (final tag in kKfzHighwayTags) {
        expect(
          runtimeKfzHighwayClasses,
          contains(tag),
          reason: 'Pipeline tag "$tag" is missing from runtime set. '
              'Check lib/features/matching/domain/way_candidate.dart.',
        );
      }
    });

    test('all runtime tags are present in pipeline set', () {
      for (final tag in runtimeKfzHighwayClasses) {
        expect(
          kKfzHighwayTags,
          contains(tag),
          reason: 'Runtime tag "$tag" is missing from pipeline set. '
              'Check tool/osm_pipeline/lib/filter/highway_class.dart.',
        );
      }
    });
  });
}
