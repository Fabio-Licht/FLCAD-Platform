import '../cad_kernel/io/kernel_io_models.dart';
import '../cad_kernel/models/kernel_models.dart';

enum CadDocumentEntityKind {
  collection,
  import,
  reference,
  curve,
  boundary,
  vertex,
  edge,
  wire,
  face,
  shell,
  solid,
  section,
  sketch,
  constraint,
  surface,
  recognition,
}

class CadDocumentEntity {
  const CadDocumentEntity({
    required this.id,
    required this.kind,
    required this.data,
    this.shape,
    this.mesh,
  });
  final String id;
  final CadDocumentEntityKind kind;
  final Map<String, dynamic> data;
  final ShapeHandle? shape;
  final KernelMeshHandle? mesh;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'data': data,
    'shape': shape?.toJson(),
    'mesh': mesh == null ? null : _meshJson(mesh!),
  };

  factory CadDocumentEntity.fromJson(Map<String, dynamic> json) =>
      CadDocumentEntity(
        id: json['id'] as String,
        kind: CadDocumentEntityKind.values.byName(json['kind'] as String),
        data: Map<String, dynamic>.from(json['data'] as Map? ?? const {}),
        shape: json['shape'] == null
            ? null
            : ShapeHandle.fromJson(
                Map<String, dynamic>.from(json['shape'] as Map),
              ),
        mesh: json['mesh'] == null
            ? null
            : _meshFromJson(Map<String, dynamic>.from(json['mesh'] as Map)),
      );

  static Map<String, dynamic> _meshJson(KernelMeshHandle value) => {
    'persistentId': value.persistentId,
    'kernelId': value.kernelId,
    'fingerprint': value.fingerprint,
    'vertexCount': value.vertexCount,
    'triangleCount': value.triangleCount,
    'bounds': value.bounds.toJson(),
    'hasNormals': value.hasNormals,
    'degenerateTriangleCount': value.degenerateTriangleCount,
    'metadata': value.metadata,
  };

  static KernelMeshHandle _meshFromJson(Map<String, dynamic> json) {
    final bounds = Map<String, dynamic>.from(json['bounds'] as Map);
    final minimum = (bounds['min'] as List).cast<num>();
    final maximum = (bounds['max'] as List).cast<num>();
    return KernelMeshHandle(
      persistentId: json['persistentId'] as String,
      kernelId: json['kernelId'] as String,
      fingerprint: json['fingerprint'] as String,
      vertexCount: json['vertexCount'] as int,
      triangleCount: json['triangleCount'] as int,
      bounds: KernelBounds(
        minimum[0].toDouble(),
        minimum[1].toDouble(),
        minimum[2].toDouble(),
        maximum[0].toDouble(),
        maximum[1].toDouble(),
        maximum[2].toDouble(),
      ),
      hasNormals: json['hasNormals'] as bool,
      degenerateTriangleCount: json['degenerateTriangleCount'] as int? ?? 0,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map? ?? const {}),
    );
  }
}

class CadDocumentRevision {
  const CadDocumentRevision(this.number, this.command, this.timestamp);
  final int number;
  final String command;
  final DateTime timestamp;
  Map<String, dynamic> toJson() => {
    'number': number,
    'command': command,
    'timestamp': timestamp.toUtc().toIso8601String(),
  };
  factory CadDocumentRevision.fromJson(Map<String, dynamic> json) =>
      CadDocumentRevision(
        json['number'] as int,
        json['command'] as String,
        DateTime.parse(json['timestamp'] as String),
      );
}

enum OfficialExportAction { keep, set, clear }

class OfficialExportUpdate {
  const OfficialExportUpdate.keep()
    : action = OfficialExportAction.keep,
      id = null;
  const OfficialExportUpdate.set(String value)
    : action = OfficialExportAction.set,
      id = value;
  const OfficialExportUpdate.clear()
    : action = OfficialExportAction.clear,
      id = null;
  final OfficialExportAction action;
  final String? id;
  String? resolve(String? previous) => switch (action) {
    OfficialExportAction.keep => previous,
    OfficialExportAction.set => id,
    OfficialExportAction.clear => null,
  };
}

class CadDocument {
  const CadDocument({
    required this.projectId,
    required this.entities,
    required this.revisions,
    required this.parameters,
    this.officialExportShapeId,
  });
  static const schema = 'flcad.cad-document';
  static const version = 1;
  final String projectId;
  final Map<String, CadDocumentEntity> entities;
  final List<CadDocumentRevision> revisions;
  final Map<String, dynamic> parameters;
  final String? officialExportShapeId;

  int get revision => revisions.length;
  ShapeHandle? get officialExportShape {
    final entity = entities[officialExportShapeId];
    return entity?.data['deleted'] == true ? null : entity?.shape;
  }

  factory CadDocument.empty(String projectId) => CadDocument(
    projectId: projectId,
    entities: const {},
    revisions: const [],
    parameters: const {},
  );

  CadDocument mutate({
    required String command,
    Iterable<CadDocumentEntity> upsert = const [],
    Iterable<String> remove = const [],
    OfficialExportUpdate officialExport = const OfficialExportUpdate.keep(),
  }) {
    final next = Map<String, CadDocumentEntity>.from(entities);
    for (final id in remove) {
      next.remove(id);
    }
    for (final entity in upsert) {
      next[entity.id] = entity;
    }
    final requestedExport = officialExport.resolve(officialExportShapeId);
    if (officialExport.action == OfficialExportAction.set) {
      final entity = next[requestedExport];
      // ExportValidation rejects temporary handles. Geometric diagnostics remain
      // the export engine's responsibility; this documentary update does no IO.
      if (entity == null ||
          entity.data['deleted'] == true ||
          entity.shape == null ||
          entity.shape!.metadata['temporary'] == true) {
        throw StateError('Invalid official export target: $requestedExport');
      }
    }
    return CadDocument(
      projectId: projectId,
      entities: Map.unmodifiable(next),
      revisions: List.unmodifiable([
        ...revisions,
        CadDocumentRevision(revision + 1, command, DateTime.now()),
      ]),
      parameters: parameters,
      officialExportShapeId: requestedExport,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'version': version,
    'projectId': projectId,
    'entities': entities.values.map((value) => value.toJson()).toList(),
    'revisions': revisions.map((value) => value.toJson()).toList(),
    'parameters': parameters,
    'officialExportShapeId': officialExportShapeId,
  };

  factory CadDocument.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema) {
      throw const FormatException('Unsupported CAD document schema.');
    }
    final entities = (json['entities'] as List? ?? const [])
        .map(
          (value) => CadDocumentEntity.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList();
    return CadDocument(
      projectId: json['projectId'] as String,
      entities: Map.unmodifiable({
        for (final value in entities) value.id: value,
      }),
      revisions: (json['revisions'] as List? ?? const [])
          .map(
            (value) => CadDocumentRevision.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList(),
      parameters: Map<String, dynamic>.from(
        json['parameters'] as Map? ?? const {},
      ),
      officialExportShapeId: json['officialExportShapeId'] as String?,
    );
  }
}
