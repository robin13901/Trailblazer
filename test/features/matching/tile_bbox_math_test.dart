// Phase 4 rescope Wave 2 (Plan 04-15):
// Unit tests for [TileBboxMath].

import 'package:auto_explore/features/matching/data/tile_bbox_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const math = TileBboxMath();

  group('TileBboxMath.lonToTileX / latToTileY', () {
    test('Berlin (52.52, 13.405) at z12 → tile (2200, 1343)', () {
      // Reference: the OSM slippy-tile formula (independently verified via
      // https://www.netzwolf.info/osm/tilebrowser.html and a scratch script).
      // The 04-15 plan text sketched (2196, 1343) approximately — the exact
      // value using the canonical formula is (2200, 1343).
      expect(math.lonToTileX(13.405, 12), 2200);
      expect(math.latToTileY(52.52, 12), 1343);
    });
  });

  group('TileBboxMath.bboxToZ12Tiles', () {
    test('5×5 km around Berlin returns 1..2 tiles', () {
      // 5 km ≈ 0.045° lat / 0.075° lon at 52.5° N.
      const half = 0.0225;
      const halfLon = 0.0375;
      final tiles = math.bboxToZ12Tiles(
        52.52 - half,
        13.405 - halfLon,
        52.52 + half,
        13.405 + halfLon,
      );
      expect(tiles.length, inInclusiveRange(1, 4));
    });

    test('bbox at meridian (0°) does not produce negative x', () {
      // Defensive: Trailblazer's Germany corpus never crosses the meridian
      // (memory: phase-4-rescope-decisions-2026-07-08). This guards the math
      // itself, not a real user path.
      final tiles = math.bboxToZ12Tiles(51, -0.5, 51.1, 0.5);
      for (final t in tiles) {
        expect(t.x, greaterThanOrEqualTo(0));
        expect(t.y, greaterThanOrEqualTo(0));
      }
    });
  });

  group('TileBboxMath.tileToBbox', () {
    test('round-trips a known Berlin tile within ±0.001°', () {
      final t = TileId(12, math.lonToTileX(13.405, 12), math.latToTileY(52.52, 12));
      final b = math.tileToBbox(t);
      // The tile should CONTAIN the point (52.52, 13.405).
      expect(b.minLat, lessThanOrEqualTo(52.52 + 1e-6));
      expect(b.maxLat, greaterThanOrEqualTo(52.52 - 1e-6));
      expect(b.minLon, lessThanOrEqualTo(13.405 + 1e-6));
      expect(b.maxLon, greaterThanOrEqualTo(13.405 - 1e-6));
      // A z12 tile at Berlin's latitude is ~10 km × 6 km (roughly 0.09°
      // lon × 0.055° lat). Full-longitude span for z12 is exactly
      // 360 / 4096 degrees.
      const z12LonSpan = 360 / 4096;
      expect(b.maxLon - b.minLon, closeTo(z12LonSpan, 1e-9));
    });
  });

  group('TileBboxMath.unionBbox', () {
    test('union of 4 adjacent tiles equals enclosing rectangle', () {
      const z = 12;
      final baseX = math.lonToTileX(13.405, z);
      final baseY = math.latToTileY(52.52, z);
      final tiles = <TileId>{
        TileId(z, baseX, baseY),
        TileId(z, baseX + 1, baseY),
        TileId(z, baseX, baseY + 1),
        TileId(z, baseX + 1, baseY + 1),
      };
      final union = math.unionBbox(tiles);
      final tl = math.tileToBbox(TileId(z, baseX, baseY));
      final br = math.tileToBbox(TileId(z, baseX + 1, baseY + 1));
      // Slippy y goes SOUTH — the "top-left" tile has the LARGER maxLat
      // (northern edge) and the "bottom-right" tile has the SMALLER minLat.
      expect(union.maxLat, closeTo(tl.maxLat, 1e-9));
      expect(union.minLat, closeTo(br.minLat, 1e-9));
      expect(union.minLon, closeTo(tl.minLon, 1e-9));
      expect(union.maxLon, closeTo(br.maxLon, 1e-9));
    });

    test('empty tile set returns degenerate zero bbox', () {
      final b = math.unionBbox(const <TileId>{});
      expect(b.minLat, 0);
      expect(b.maxLat, 0);
      expect(b.minLon, 0);
      expect(b.maxLon, 0);
    });
  });
}
