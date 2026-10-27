import 'dart:math' as math;

import '../../utils/id_generator.dart';
import '../geometry/sketch_spline_geometry.dart';
import '../models/sketch_models.dart';

enum SketchEntityType {
  point,
  line,
  circle,
  arc,
  spline,
  ellipse,
  construction,
  reference,
}

enum SketchSelectionState { none, hovered, preselected, selected }

abstract class SketchEntity {
  SketchEntity({
    required this.type,
    required this.parameters,
    String? id,
    this.owner = 'local',
    DateTime? timestamp,
    this.version = 1,
    List<String>? history,
    String? graphNode,
    this.selectionState = SketchSelectionState.none,
    this.visible = true,
    this.locked = false,
    this.construction = false,
    this.reference = false,
    Map<String, dynamic>? metadata,
    List<String>? diagnostics,
  }) : id = id ?? 'ske:${IdGenerator.generate()}',
       timestamp = timestamp ?? DateTime.now().toUtc(),
       history = history ?? <String>[],
       graphNode = graphNode ?? '',
       metadata = metadata ?? <String, dynamic>{},
       diagnostics = diagnostics ?? <String>[];
  final String id;
  final SketchEntityType type;
  final String owner;
  final DateTime timestamp;
  int version;
  final List<String> history;
  String graphNode;
  SketchSelectionState selectionState;
  bool visible;
  bool locked;
  bool construction;
  bool reference;
  final Map<String, dynamic> metadata;
  final List<String> diagnostics;
  final Map<String, dynamic> parameters;

  /// Keeps non-authoritative Inspector/HUD values synchronized after every
  /// edit path (numeric, move, rotate, scale or constraint solving).
  void refreshDerivedParameters() {
    if (this is SketchLine) {
      final start = SketchVector.fromJson(parameters['start']);
      final end = SketchVector.fromJson(parameters['end']);
      parameters
        ..clear()
        ..addAll(SketchLine.parametersFor(start, end));
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'owner': owner,
    'timestamp': timestamp.toIso8601String(),
    'version': version,
    'history': history,
    'graphNode': graphNode.isEmpty ? id : graphNode,
    'selectionState': selectionState.name,
    'visible': visible,
    'locked': locked,
    'construction': construction,
    'reference': reference,
    'metadata': metadata,
    'diagnostics': diagnostics,
    'parameters': parameters,
  };

  static SketchEntity fromJson(Map<String, dynamic> json) {
    final type = SketchEntityType.values.byName(json['type'] as String);
    final p = (json['parameters'] as Map).cast<String, dynamic>();
    final id = json['id'] as String;
    final owner = json['owner'] as String? ?? 'local';
    final timestamp = json['timestamp'] == null
        ? null
        : DateTime.parse(json['timestamp'] as String);
    SketchEntity entity;
    switch (type) {
      case SketchEntityType.point:
        entity = SketchPoint(
          SketchVector.fromJson(p['point']),
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
      case SketchEntityType.line:
        entity = SketchLine(
          SketchVector.fromJson(p['start']),
          SketchVector.fromJson(p['end']),
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
      case SketchEntityType.circle:
        entity = SketchCircle(
          SketchVector.fromJson(p['center']),
          (p['radius'] as num).toDouble(),
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
      case SketchEntityType.arc:
        entity = SketchArc(
          SketchVector.fromJson(p['center']),
          (p['radius'] as num).toDouble(),
          (p['startAngle'] as num).toDouble(),
          (p['endAngle'] as num).toDouble(),
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
      case SketchEntityType.spline:
        entity = SketchSpline(
          (p['points'] as List).map(SketchVector.fromJson).toList(),
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        entity.parameters.addAll(p);
        break;
      case SketchEntityType.ellipse:
        entity = SketchEllipse(
          SketchVector.fromJson(p['center']),
          (p['radiusX'] as num).toDouble(),
          (p['radiusY'] as num).toDouble(),
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
      case SketchEntityType.construction:
        entity = ConstructionGeometry(
          p,
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
      case SketchEntityType.reference:
        entity = ReferenceGeometry(
          p,
          id: id,
          owner: owner,
          timestamp: timestamp,
        );
        break;
    }
    entity.version = json['version'] as int;
    entity.history.addAll((json['history'] as List).cast<String>());
    entity.graphNode = json['graphNode'] as String;
    entity.selectionState = SketchSelectionState.values.byName(
      json['selectionState'] as String,
    );
    entity.visible = json['visible'] as bool;
    entity.locked = json['locked'] as bool;
    entity.construction = json['construction'] as bool;
    entity.reference = json['reference'] as bool;
    entity.metadata.addAll((json['metadata'] as Map).cast<String, dynamic>());
    entity.diagnostics.addAll((json['diagnostics'] as List).cast<String>());
    return entity;
  }
}

class SketchPoint extends SketchEntity {
  SketchPoint(
    SketchVector point, {
    super.id,
    super.owner,
    super.timestamp,
  })
    : super(
        type: SketchEntityType.point,
        parameters: {'point': point.toJson()},
      );
}

class SketchLine extends SketchEntity {
  SketchLine(
    SketchVector start,
    SketchVector end, {
    super.id,
    super.owner,
    super.timestamp,
  })
    : super(type: SketchEntityType.line, parameters: parametersFor(start, end));

  static Map<String, dynamic> parametersFor(
    SketchVector start,
    SketchVector end,
  ) {
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final dz = end.z - start.z;
    final length = math.sqrt(dx * dx + dy * dy + dz * dz);
    return {
      'start': start.toJson(),
      'end': end.toJson(),
      'length': length,
      'direction': length <= 1e-12
          ? const [0.0, 0.0, 0.0]
          : [dx / length, dy / length, dz / length],
      'angleDegrees': math.atan2(dy, dx) * 180 / math.pi,
    };
  }
}

class SketchCircle extends SketchEntity {
  SketchCircle(
    SketchVector center,
    double radius, {
    super.id,
    super.owner,
    super.timestamp,
  })
    : super(
        type: SketchEntityType.circle,
        parameters: {'center': center.toJson(), 'radius': radius},
      );
}

class SketchArc extends SketchEntity {
  SketchArc(
    SketchVector center,
    double radius,
    double startAngle,
    double endAngle, {
    super.id,
    super.owner,
    super.timestamp,
  }) : super(
         type: SketchEntityType.arc,
         parameters: {
           'center': center.toJson(),
           'radius': radius,
           'startAngle': startAngle,
           'endAngle': endAngle,
         },
       );
}

class SketchSpline extends SketchEntity {
  SketchSpline(
    List<SketchVector> points, {
    super.id,
    super.owner,
    super.timestamp,
    List<SketchVector>? bezierControls,
  }) : super(
         type: SketchEntityType.spline,
         parameters: {
           'points': points.map((e) => e.toJson()).toList(),
           'interpolation': bezierControls == null
               ? 'centripetalCatmullRom'
               : 'cubicBezierG1',
           if (bezierControls != null)
             'bezierControls': bezierControls.map((e) => e.toJson()).toList(),
           'sampledPoints':
               (bezierControls == null
                       ? SketchSplineGeometry.interpolate(points)
                       : SketchSplineGeometry.cubicBezier(bezierControls))
                   .map((e) => e.toJson())
                   .toList(),
         },
       );
}

class SketchEllipse extends SketchEntity {
  SketchEllipse(
    SketchVector center,
    double radiusX,
    double radiusY, {
    super.id,
    super.owner,
    super.timestamp,
  })
    : super(
        type: SketchEntityType.ellipse,
        parameters: {
          'center': center.toJson(),
          'radiusX': radiusX,
          'radiusY': radiusY,
        },
      );
}

class ConstructionGeometry extends SketchEntity {
  ConstructionGeometry(
    Map<String, dynamic> parameters, {
    super.id,
    super.owner,
    super.timestamp,
  })
    : super(
        type: SketchEntityType.construction,
        parameters: parameters,
        construction: true,
      );
}

class ReferenceGeometry extends SketchEntity {
  ReferenceGeometry(
    Map<String, dynamic> parameters, {
    super.id,
    super.owner,
    super.timestamp,
  })
    : super(
        type: SketchEntityType.reference,
        parameters: parameters,
        reference: true,
      );
}
