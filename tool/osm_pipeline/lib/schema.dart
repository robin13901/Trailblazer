/// Version stamp constants for pipeline outputs.
///
/// Bump [pipelineSchemaVersion] whenever the on-disk schema of `osm.sqlite`
/// or the pmtiles layer inventory changes in a way that breaks Phase 5's
/// integrity check. Phase 5 reads this value from `PRAGMA user_version`
/// and cross-checks the same integer against pmtiles metadata.
///
/// Version history:
///   * v1 (2026-07-05 · Plan 04-06): initial osm.sqlite + pmtiles schema.
///   * v2 (2026-07-07 · Plan 04-10.1): Feldweg dropped from osm.sqlite
///     ways table. Feldweg still lands in the pmtiles `roads` layer as
///     static base geometry per REN-02; only the driven-per-way state-
///     coloring path (Kfz-only) is affected. Any prior Berlin/Germany
///     osm.sqlite artifact on disk is stale under v2 — Phase 5 must
///     re-generate.
const int pipelineSchemaVersion = 2;

/// Semantic pipeline release marker (informational only).
const String pipelineName = 'trailblazer-osm-pipeline';
