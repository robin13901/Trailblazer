// TripStatus — persisted as TEXT ('recording' | 'pending' | 'matched' |
// 'confirmed' | 'rejected') via TripStatusConverter.
// Do NOT reorder or rename values — SQL stored as enum name; any rename
// requires a data migration.
enum TripStatus { recording, pending, matched, confirmed, rejected }
