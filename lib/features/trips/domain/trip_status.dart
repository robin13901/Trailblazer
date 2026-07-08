// TripStatus — persisted as TEXT ('recording' | 'pendingRoadData' | 'pending'
// | 'matched' | 'confirmed' | 'rejected') via TripStatusConverter.
// Do NOT reorder or rename values — SQL stored as enum name; any rename
// requires a data migration. Inserting a new value in the middle is safe
// (converter uses `.name`, not the enum ordinal).
//
// State flow: recording → pendingRoadData → pending → matched → confirmed
// (or → rejected at any point after `pending`). The pendingRoadData state
// was added in Plan 04-15 (2026-07-08) — trips transition here after Stop
// while the coordinator either fetches Overpass road data (online) or
// enqueues a pending_road_fetches row (offline). Once road data is present
// the trip advances to `pending` and the map-matcher (Phase 5) takes over.
enum TripStatus {
  recording,
  pendingRoadData,
  pending,
  matched,
  confirmed,
  rejected,
}
