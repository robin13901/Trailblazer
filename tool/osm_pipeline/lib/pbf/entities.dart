/// OpenStreetMap entity model — sealed hierarchy of `Node`, `Way`, `Relation`.
///
/// See the OSM data model: https://wiki.openstreetmap.org/wiki/Elements
///
/// All entities carry an `id` and a `tags` map. Node ids, way node refs, and
/// relation member ids are `int` — on 64-bit Dart these fit OSM's int64 range
/// (max observed OSM id at time of writing is ~1.2e10, well under 2^53).
library;

/// Base for all OSM entities read from a `.osm.pbf` file.
sealed class OsmEntity {
  /// Create an OSM entity with the given [id] and [tags].
  const OsmEntity({required this.id, required this.tags});

  /// OSM entity id. Unique within its entity type namespace (nodes, ways,
  /// and relations each have their own id space).
  final int id;

  /// Free-form tag map (may be empty). Keys and values are UTF-8 strings
  /// resolved from the PBF PrimitiveBlock's string table at decode time.
  final Map<String, String> tags;
}

/// A single lat/lng point in the OSM graph.
final class OsmNode extends OsmEntity {
  /// Create a node.
  const OsmNode({
    required super.id,
    required super.tags,
    required this.lat,
    required this.lng,
  });

  /// Latitude in decimal degrees, WGS84.
  final double lat;

  /// Longitude in decimal degrees, WGS84.
  final double lng;
}

/// A polyline (or ring) referencing a sequence of node ids by reference.
final class OsmWay extends OsmEntity {
  /// Create a way. [nodeRefs] must be non-empty in valid data; the reader
  /// does not enforce this — downstream filters own that concern.
  const OsmWay({
    required super.id,
    required super.tags,
    required this.nodeRefs,
  });

  /// Ordered list of node ids the way traverses.
  final List<int> nodeRefs;
}

/// A relation collecting nodes / ways / other relations under named roles.
final class OsmRelation extends OsmEntity {
  /// Create a relation.
  const OsmRelation({
    required super.id,
    required super.tags,
    required this.members,
  });

  /// The relation's ordered member list.
  final List<RelationMember> members;
}

/// The kind of an [OsmRelation] member.
enum OsmMemberType {
  /// A node member.
  node,

  /// A way member.
  way,

  /// A nested relation member.
  relation,
}

/// One member reference inside an [OsmRelation].
class RelationMember {
  /// Create a relation member.
  const RelationMember({
    required this.refId,
    required this.type,
    required this.role,
  });

  /// The referenced entity's id (in the [type] namespace).
  final int refId;

  /// The referenced entity's type.
  final OsmMemberType type;

  /// The member's role string (`outer`, `inner`, `admin_centre`, `''`, ...).
  final String role;
}

/// OSM header block payload — captured from the first `OSMHeader` blob and
/// exposed on `PbfReader.header` so downstream stages can seed the pipeline's
/// `pbf_date` metadata (04-RESEARCH §9).
class HeaderBlock {
  /// Create a header block.
  const HeaderBlock({
    required this.requiredFeatures,
    required this.optionalFeatures,
    this.bbox,
    this.writingProgram,
    this.source,
    this.osmosisReplicationTimestamp,
  });

  /// Features the reader must understand — reader throws on unknown ones.
  final List<String> requiredFeatures;

  /// Features the reader may skip if it does not recognise them.
  final List<String> optionalFeatures;

  /// Optional geographical bounding box of the extract.
  final HeaderBoundingBox? bbox;

  /// Optional identifier of the program that wrote the PBF.
  final String? writingProgram;

  /// Optional free-form source identifier.
  final String? source;

  /// Optional Unix timestamp (seconds) of the replication cut.
  final int? osmosisReplicationTimestamp;
}

/// A header's declared bounding box, in decimal degrees.
class HeaderBoundingBox {
  /// Create a header bounding box.
  const HeaderBoundingBox({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  /// Western longitude.
  final double left;

  /// Eastern longitude.
  final double right;

  /// Northern latitude.
  final double top;

  /// Southern latitude.
  final double bottom;
}
