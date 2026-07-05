/// Highway classification constants for the Trailblazer OSM pipeline.
///
/// Derived from `REQUIREMENTS.md:OSM-02` (post 04-01 reconciliation) and
/// `04-RESEARCH.md` §5 (implicit-oneway rule).
///
/// The Kfz allowlist is deliberately narrow — `highway=service` is excluded
/// (see STATE.md Plan 04-01). Service ways re-enter via the Feldweg side-door
/// (`service=driveway|alley`) only.
library;

/// The 14 Kfz-classified highway values from OSM-02 (post-reconciliation).
///
/// `service` is deliberately excluded — service-way sprawl (parking lots,
/// driveways, station forecourts) blows the 200 MB budget with minimal
/// driven-experience value.
const Set<String> kKfzHighwayTags = {
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

/// OSM implicit-oneway classes — a Kfz way with no `oneway` tag but this
/// highway class is treated as one-way in the forward direction per the
/// OSM wiki (https://wiki.openstreetmap.org/wiki/Key:oneway).
///
/// Only `motorway`, `motorway_link`, and `trunk_link` are implicit-oneway;
/// `trunk` itself is NOT (see 04-RESEARCH §5 test-case notes).
const Set<String> kImplicitOnewayKfzTags = {
  'motorway',
  'motorway_link',
  'trunk_link',
};
