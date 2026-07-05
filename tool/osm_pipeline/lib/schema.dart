/// Version stamp constants for pipeline outputs.
///
/// Bump [pipelineSchemaVersion] whenever the on-disk schema of `osm.sqlite`
/// or the pmtiles layer inventory changes in a way that breaks Phase 5's
/// integrity check. Phase 5 reads this value from `PRAGMA user_version`
/// and cross-checks the same integer against pmtiles metadata.
const int pipelineSchemaVersion = 1;

/// Semantic pipeline release marker (informational only).
const String pipelineName = 'trailblazer-osm-pipeline';
