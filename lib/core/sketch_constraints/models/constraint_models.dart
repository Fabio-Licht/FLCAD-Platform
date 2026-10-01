import '../../utils/id_generator.dart';

enum SketchConstraintType {
  coincident,
  horizontal,
  vertical,
  parallel,
  perpendicular,
  equal,
  concentric,
  collinear,
  midpoint,
  symmetric,
  tangent,
  fixed,
  lock,
  distance,
  radius,
  diameter,
  angle,
  offset,
  pointOnCurve,
  pointOnCircle,
  pointOnArc,
  pointOnLine,
  reference,
  drivenDimension,
  drivingDimension,
  construction,
}

enum ConstraintStatus {
  satisfied,
  unsatisfied,
  conflicting,
  overdefined,
  underdefined,
  suppressed,
  driven,
  driving,
  disabled,
  invalid,
}

class SketchConstraint {
  SketchConstraint({
    required this.type,
    required List<String> references,
    this.value,
    this.owner = 'local',
    this.priority = 0,
    this.status = ConstraintStatus.unsatisfied,
    String? id,
    DateTime? timestamp,
    this.version = 1,
    List<String>? history,
    String? graphNode,
    Map<String, dynamic>? metadata,
    List<String>? diagnostics,
  }) : id = id ?? 'constraint:${IdGenerator.generate()}',
       references = List.of(references),
       timestamp = timestamp ?? DateTime.now().toUtc(),
       history = history ?? <String>[],
       graphNode = graphNode ?? '',
       metadata = metadata ?? <String, dynamic>{},
       diagnostics = diagnostics ?? <String>[];
  final String id;
  final SketchConstraintType type;
  final List<String> references;
  double? value;
  final String owner;
  int priority;
  ConstraintStatus status;
  final List<String> diagnostics;
  final Map<String, dynamic> metadata;
  final DateTime timestamp;
  int version;
  final List<String> history;
  String graphNode;
  bool get enabled => status != ConstraintStatus.disabled;
  bool get suppressed => status == ConstraintStatus.suppressed;
  bool get visible => metadata['visible'] as bool? ?? true;
  bool get driving =>
      type == SketchConstraintType.drivingDimension ||
      status == ConstraintStatus.driving;
  bool get driven =>
      type == SketchConstraintType.drivenDimension ||
      status == ConstraintStatus.driven;
  String get signature => '${type.name}:${references.join('|')}:${value ?? ''}';
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'references': references,
    'value': value,
    'owner': owner,
    'priority': priority,
    'status': status.name,
    'diagnostics': diagnostics,
    'metadata': metadata,
    'timestamp': timestamp.toIso8601String(),
    'version': version,
    'history': history,
    'graphNode': graphNode.isEmpty ? id : graphNode,
  };
  factory SketchConstraint.fromJson(Map<String, dynamic> j) => SketchConstraint(
    id: j['id'] as String,
    type: SketchConstraintType.values.byName(j['type'] as String),
    references: (j['references'] as List).cast<String>(),
    value: (j['value'] as num?)?.toDouble(),
    owner: j['owner'] as String,
    priority: j['priority'] as int,
    status: ConstraintStatus.values.byName(j['status'] as String),
    diagnostics: (j['diagnostics'] as List).cast<String>(),
    metadata: (j['metadata'] as Map).cast<String, dynamic>(),
    timestamp: DateTime.parse(j['timestamp'] as String),
    version: j['version'] as int,
    history: (j['history'] as List).cast<String>(),
    graphNode: j['graphNode'] as String,
  );
}

enum SketchDimensionType {
  linear,
  horizontal,
  vertical,
  parallelDistance,
  ordinateX,
  ordinateY,
  angular,
  radius,
  diameter,
  offset,
  reference,
  driven,
  driving,
}

class SketchDimension {
  SketchDimension({
    required this.type,
    required this.constraintId,
    required this.value,
    List<String> references = const [],
    this.anchorReference,
    this.orientationSign,
    this.labelX = 0,
    this.labelY = 0,
    this.visible = true,
    String? id,
  }) : id = id ?? 'dimension:${IdGenerator.generate()}',
       references = List.of(references);
  final String id;
  final SketchDimensionType type;
  final String constraintId;
  final List<String> references;
  String? anchorReference;
  final double? orientationSign;
  double value;
  double labelX, labelY;
  bool visible;
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'constraintId': constraintId,
    'references': references,
    'anchorReference': anchorReference,
    'orientationSign': orientationSign,
    'value': value,
    'labelX': labelX,
    'labelY': labelY,
    'visible': visible,
  };
  factory SketchDimension.fromJson(Map<String, dynamic> j) => SketchDimension(
    id: j['id'] as String,
    type: SketchDimensionType.values.byName(j['type'] as String),
    constraintId: j['constraintId'] as String,
    references: (j['references'] as List?)?.cast<String>() ?? const [],
    anchorReference: j['anchorReference'] as String?,
    orientationSign: (j['orientationSign'] as num?)?.toDouble(),
    value: (j['value'] as num).toDouble(),
    labelX: (j['labelX'] as num?)?.toDouble() ?? 0,
    labelY: (j['labelY'] as num?)?.toDouble() ?? 0,
    visible: j['visible'] as bool? ?? true,
  );
}

class ConstraintGroup {
  ConstraintGroup(
    this.name, {
    String? id,
    Iterable<String> constraintIds = const [],
  }) : id = id ?? 'constraint-group:${IdGenerator.generate()}',
       constraintIds = constraintIds.toSet();
  final String id;
  final String name;
  final Set<String> constraintIds;
}
