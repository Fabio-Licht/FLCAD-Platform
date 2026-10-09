import 'dart:math' as math;

import '../../sketch_engine/entities/sketch_entities.dart';
import '../../sketch_engine/models/sketch_models.dart';
import '../models/constraint_models.dart';

/// Classification of the geometry found at one end of an arc before a radius
/// edit is applied.
enum ArcRadiusBoundaryKind {
  free,
  coincident,
  tangent,
  fixed,
  dimensioned,
  ambiguous,
  gap,
}

/// Immutable inputs for [ArcRadiusEditPlanner].  The planner only reads these
/// objects; it never changes an entity, constraint, engine or document.
class ArcRadiusEditContext {
  const ArcRadiusEditContext({
    required this.entities,
    this.constraints = const <SketchConstraint>[],
    this.connectionTolerance = 1e-4,
    this.gapTolerance = .1,
    this.frontierTolerance,
    this.tangencyTolerance = 1e-6,
    this.confirmationThreshold,
  });

  final Iterable<SketchEntity> entities;
  final Iterable<SketchConstraint> constraints;
  final double connectionTolerance;
  final double gapTolerance;

  /// When omitted, the existing reconstruction rule is used:
  /// max(0.25 mm, 1% of the old radius).
  final double? frontierTolerance;
  final double tangencyTolerance;

  /// Optional caller-provided confirmation policy.  The planner does not
  /// invent a displacement limit; it reports the measured displacement and
  /// only sets [ArcRadiusEditPlan.requiresConfirmation] when this value is
  /// supplied and exceeded.
  final double? confirmationThreshold;
}

class ArcRadiusGeometry {
  const ArcRadiusGeometry({
    required this.center,
    required this.radius,
    required this.startAngle,
    required this.endAngle,
  });

  final SketchVector center;
  final double radius;
  final double startAngle;
  final double endAngle;
}

class ArcRadiusBoundaryPlan {
  const ArcRadiusBoundaryPlan({
    required this.endpoint,
    required this.kind,
    required this.entityId,
    required this.entityEndpoint,
    required this.gap,
    required this.tangencyResidualBefore,
    required this.tangencyResidualAfter,
    required this.endpointDisplacement,
    required this.fixed,
    required this.dimensioned,
  });

  final String endpoint;
  final ArcRadiusBoundaryKind kind;
  final String? entityId;
  final String? entityEndpoint;
  final double gap;
  final double tangencyResidualBefore;
  final double tangencyResidualAfter;
  final double endpointDisplacement;
  final bool fixed;
  final bool dimensioned;
}

/// A complete, side-effect-free radius edit proposal.
class ArcRadiusEditPlan {
  const ArcRadiusEditPlan._({
    required this.accepted,
    required this.arc,
    required this.boundaries,
    required this.endpointUpdates,
    required this.affectedEntityIds,
    required this.maxEndpointDisplacement,
    required this.maxCoincidenceResidual,
    required this.maxTangencyResidual,
    required this.requiresConfirmation,
    this.previousRadius,
    this.requestedRadius,
    this.diagnostic,
  });

  factory ArcRadiusEditPlan.success({
    required ArcRadiusGeometry arc,
    required List<ArcRadiusBoundaryPlan> boundaries,
    required Map<String, Map<String, double>> endpointUpdates,
    required Set<String> affectedEntityIds,
    required double maxEndpointDisplacement,
    required double maxCoincidenceResidual,
    required double maxTangencyResidual,
    required bool requiresConfirmation,
    required double previousRadius,
    required double requestedRadius,
    String? diagnostic,
  }) => ArcRadiusEditPlan._(
    accepted: true,
    arc: arc,
    boundaries: List.unmodifiable(boundaries),
    endpointUpdates: Map<String, Map<String, double>>.unmodifiable({
      for (final entry in endpointUpdates.entries)
        entry.key: Map<String, double>.unmodifiable(entry.value),
    }),
    affectedEntityIds: Set.unmodifiable(affectedEntityIds),
    maxEndpointDisplacement: maxEndpointDisplacement,
    maxCoincidenceResidual: maxCoincidenceResidual,
    maxTangencyResidual: maxTangencyResidual,
    requiresConfirmation: requiresConfirmation,
    previousRadius: previousRadius,
    requestedRadius: requestedRadius,
    diagnostic: diagnostic,
  );

  factory ArcRadiusEditPlan.rejected(String diagnostic) => ArcRadiusEditPlan._(
    accepted: false,
    arc: null,
    boundaries: const [],
    endpointUpdates: const {},
    affectedEntityIds: const {},
    maxEndpointDisplacement: 0,
    maxCoincidenceResidual: 0,
    maxTangencyResidual: 0,
    requiresConfirmation: false,
    diagnostic: diagnostic,
  );

  final bool accepted;
  final ArcRadiusGeometry? arc;
  final List<ArcRadiusBoundaryPlan> boundaries;
  final Map<String, Map<String, double>> endpointUpdates;
  final Set<String> affectedEntityIds;
  final double maxEndpointDisplacement;
  final double maxCoincidenceResidual;
  final double maxTangencyResidual;
  final bool requiresConfirmation;
  final double? previousRadius;
  final double? requestedRadius;
  final String? diagnostic;

  bool get hasExternalUpdates => endpointUpdates.isNotEmpty;

  /// Compares two immutable proposals without comparing object identity.
  /// Confirmation uses this to reject a preview whose geometry was changed
  /// before Apply instead of silently accepting a different solution.
  bool equivalentTo(ArcRadiusEditPlan other, {double tolerance = 1e-9}) {
    bool close(double? first, double? second) {
      if (first == null || second == null) return first == second;
      return (first - second).abs() <= tolerance;
    }

    bool geometryEqual(ArcRadiusGeometry? first, ArcRadiusGeometry? second) {
      if (first == null || second == null) return first == second;
      return close(first.center.x, second.center.x) &&
          close(first.center.y, second.center.y) &&
          close(first.center.z, second.center.z) &&
          close(first.radius, second.radius) &&
          close(first.startAngle, second.startAngle) &&
          close(first.endAngle, second.endAngle);
    }

    if (accepted != other.accepted ||
        !geometryEqual(arc, other.arc) ||
        !close(previousRadius, other.previousRadius) ||
        !close(requestedRadius, other.requestedRadius) ||
        affectedEntityIds.length != other.affectedEntityIds.length ||
        !affectedEntityIds.containsAll(other.affectedEntityIds) ||
        !close(maxEndpointDisplacement, other.maxEndpointDisplacement) ||
        !close(maxCoincidenceResidual, other.maxCoincidenceResidual) ||
        !close(maxTangencyResidual, other.maxTangencyResidual) ||
        endpointUpdates.length != other.endpointUpdates.length) {
      return false;
    }
    for (final entry in endpointUpdates.entries) {
      final otherValues = other.endpointUpdates[entry.key];
      if (otherValues == null || otherValues.length != entry.value.length) {
        return false;
      }
      for (final value in entry.value.entries) {
        if (!close(value.value, otherValues[value.key])) return false;
      }
    }
    return true;
  }

  Map<String, Object?> get diagnosticDetails => {
    'previousRadiusMm': previousRadius,
    'requestedRadiusMm': requestedRadius,
    'affectedEntityIds': affectedEntityIds.toList(growable: false),
    'endpointUpdates': endpointUpdates,
    'maxEndpointDisplacementMm': maxEndpointDisplacement,
    'maxCoincidenceResidual': maxCoincidenceResidual,
    'maxTangencyResidual': maxTangencyResidual,
    'requiresConfirmation': hasExternalUpdates,
    if (diagnostic != null) 'diagnostic': diagnostic,
  };
}

/// Raised before a radius edit can mutate adjacent entities.
///
/// The plan is retained so a future preview/confirmation UI can present the
/// exact affected IDs, displacement and C0/G1 residuals without replanning.
class ArcRadiusEditConfirmationRequired implements Exception {
  ArcRadiusEditConfirmationRequired(this.plan)
    : message = _message(plan);

  final ArcRadiusEditPlan plan;
  final String message;

  Map<String, Object?> get details => plan.diagnosticDetails;

  @override
  String toString() => message;

  static String _message(ArcRadiusEditPlan plan) {
    final before = plan.previousRadius?.toStringAsFixed(6) ?? '?';
    final after = plan.requestedRadius?.toStringAsFixed(6) ?? '?';
    final ids = plan.affectedEntityIds.join(', ');
    return 'Confirmação necessária para editar o raio de $before para '
        '$after mm: entidades adjacentes ($ids) seriam deslocadas; '
        'deslocamento máximo ${plan.maxEndpointDisplacement.toStringAsFixed(6)} '
        'mm, resíduo C0 ${plan.maxCoincidenceResidual.toStringAsExponential(3)}, '
        'resíduo G1 ${plan.maxTangencyResidual.toStringAsExponential(3)}.';
  }
}

/// Builds a safe geometric proposal for changing an arc radius.
///
/// The planner remains pure: both the Property Inspector and driving-dimension
/// paths consume the same proposal, then apply it inside their own existing
/// transactions.
class ArcRadiusEditPlanner {
  const ArcRadiusEditPlanner();

  ArcRadiusEditPlan plan({
    required SketchArc arc,
    required double radius,
    required ArcRadiusEditContext context,
  }) {
    if (!radius.isFinite || radius <= 0) {
      return ArcRadiusEditPlan.rejected('O raio deve ser finito e positivo.');
    }
    final oldRadius = _number(arc.parameters['radius']);
    final center = _vector(arc.parameters['center']);
    final oldStart = _number(arc.parameters['startAngle']);
    final oldEnd = _number(arc.parameters['endAngle']);
    if (oldRadius == null ||
        center == null ||
        oldStart == null ||
        oldEnd == null ||
        oldRadius <= 0 ||
        !oldRadius.isFinite ||
        !center._finite ||
        !oldStart.isFinite ||
        !oldEnd.isFinite) {
      return ArcRadiusEditPlan.rejected(
        'O arco possui parâmetros inválidos ou não finitos.',
      );
    }
    if (!_finiteContext(context)) {
      return ArcRadiusEditPlan.rejected(
        'O contexto da edição possui tolerâncias inválidas.',
      );
    }
    if (_hasEntityConstraint(context.constraints, arc.id, const {
      SketchConstraintType.fixed,
      SketchConstraintType.lock,
    })) {
      return ArcRadiusEditPlan.rejected(
        'O arco possui uma constraint fixa e não pode mudar de raio.',
      );
    }
    final dimensionConstraint = context.constraints
        .where(
          (constraint) =>
              constraint.enabled &&
              !constraint.suppressed &&
              const {
                SketchConstraintType.radius,
                SketchConstraintType.diameter,
                SketchConstraintType.drivingDimension,
                SketchConstraintType.drivenDimension,
              }.contains(constraint.type) &&
              constraint.references.any(
                (reference) =>
                    reference == arc.id || reference.startsWith('${arc.id}:'),
              ),
        )
        .firstOrNull;
    if (dimensionConstraint != null) {
      return ArcRadiusEditPlan.rejected(
        'A cota ${dimensionConstraint.id} impede editar o raio diretamente.',
      );
    }

    final oldEndpoints = [
      _pointAt(center, oldRadius, oldStart),
      _pointAt(center, oldRadius, oldEnd),
    ];
    if (oldEndpoints.any((point) => !point._finite)) {
      return ArcRadiusEditPlan.rejected(
        'Os endpoints calculados do arco não são finitos.',
      );
    }
    final boundaries = <_BoundaryCandidate>[];
    for (var index = 0; index < 2; index++) {
      boundaries.add(
        _findBoundary(
          arc: arc,
          endpoint: index == 0 ? 'start' : 'end',
          center: center,
          point: oldEndpoints[index],
          context: context,
        ),
      );
    }

    if (boundaries.any((item) => item.ambiguous)) {
      return ArcRadiusEditPlan.rejected(
        'Fronteira ambígua: selecione uma única conexão em cada extremidade.',
      );
    }
    if (boundaries.any(
      (item) =>
          item.kind == ArcRadiusBoundaryKind.gap &&
          item.gap > context.gapTolerance,
    )) {
      return ArcRadiusEditPlan.rejected(
        'Existe um gap preexistente em uma fronteira '
        '(tolerância ${context.gapTolerance} mm); a edição não o corrige automaticamente.',
      );
    }

    final matched = boundaries.where((item) => item.entity != null).toList();
    final reconstructedArc = arc.metadata['reconstructionKind'] == 'arc';
    if (reconstructedArc && matched.length != 2) {
      return ArcRadiusEditPlan.rejected(
        'Não foi possível manter a tangência nas duas fronteiras.',
      );
    }
    if (matched.length == 2 && matched[0].entity!.id == matched[1].entity!.id) {
      return ArcRadiusEditPlan.rejected(
        'A mesma entidade não pode ser as duas fronteiras do arco.',
      );
    }
    if (matched.any((item) => item.entity is SketchSpline)) {
      return ArcRadiusEditPlan.rejected(
        'A fronteira spline exige continuidade de controle; esta edição segura ainda não é suportada.',
      );
    }
    if (matched.any((item) => item.entity is! SketchLine)) {
      return ArcRadiusEditPlan.rejected(
        'A fronteira circular não possui um solucionador seguro nesta etapa.',
      );
    }

    final geometry = switch (matched.length) {
      0 => _keepEndpoints(
        center: center,
        oldRadius: oldRadius,
        oldStart: oldStart,
        oldEnd: oldEnd,
        radius: radius,
      ),
      1 => _solveOneLine(
        center: center,
        oldStart: oldStart,
        oldEnd: oldEnd,
        radius: radius,
        matched: matched.single,
        oldEndpoints: oldEndpoints,
        tangencyTolerance: context.tangencyTolerance,
      ),
      _ => _solveTwoLines(
        center: center,
        oldStart: oldStart,
        oldEnd: oldEnd,
        radius: radius,
        boundaries: matched,
        tangencyTolerance: context.tangencyTolerance,
      ),
    };
    if (geometry == null) {
      return ArcRadiusEditPlan.rejected(
        matched.isEmpty
            ? 'O raio não é compatível com os dois endpoints do arco.'
            : 'Não foi encontrada uma solução tangente não degenerada para as fronteiras.',
      );
    }
    if (geometry.contacts.length != 2 ||
        !geometry.center._finite ||
        geometry.contacts.any((point) => !point._finite)) {
      return ArcRadiusEditPlan.rejected(
        'A solução do raio produziu geometria não finita.',
      );
    }

    final updates = <String, Map<String, double>>{};
    final plans = <ArcRadiusBoundaryPlan>[];
    var maxMove = 0.0;
    var maxC0 = 0.0;
    var maxG1 = 0.0;
    for (var index = 0; index < boundaries.length; index++) {
      final boundary = boundaries[index];
      final endpointName = index == 0 ? 'start' : 'end';
      final contact = geometry.contacts[index];
      final residual = contact.distanceTo(oldEndpoints[index]);
      boundary.plannedDisplacement = residual;
      maxMove = math.max(maxMove, residual);
      if (boundary.entity case final SketchLine line) {
        final key = boundary.entityEndpoint!;
        updates[line.id] = {
          '${key}X': contact.x,
          '${key}Y': contact.y,
          '${key}Z': contact.z,
        };
        final other = boundary.other!;
        final direction = contact - other;
        final radial = contact - geometry.center;
        final directionLength = direction.length2d;
        final radialLength = radial.length2d;
        final originalDirection = boundary.attached! - other;
        final c0 = directionLength <= 1e-12
            ? double.infinity
            : direction.cross2d(originalDirection).abs() / directionLength;
        final g1 = directionLength <= 1e-12 || radialLength <= 1e-12
            ? double.infinity
            : (direction.x * radial.x + direction.y * radial.y).abs() /
                  (directionLength * radialLength);
        if (!c0.isFinite || !g1.isFinite) {
          return ArcRadiusEditPlan.rejected(
            'A fronteira ${line.id} é degenerada.',
          );
        }
        maxG1 = math.max(maxG1, g1);
        plans.add(
          ArcRadiusBoundaryPlan(
            endpoint: endpointName,
            kind: boundary.kind,
            entityId: line.id,
            entityEndpoint: key,
            gap: boundary.gap,
            tangencyResidualBefore: boundary.tangencyResidual,
            tangencyResidualAfter: g1,
            endpointDisplacement: residual,
            fixed: boundary.fixed,
            dimensioned: boundary.dimensioned,
          ),
        );
        maxC0 = math.max(maxC0, c0);
      } else {
        plans.add(
          ArcRadiusBoundaryPlan(
            endpoint: endpointName,
            kind: boundary.kind,
            entityId: null,
            entityEndpoint: null,
            gap: boundary.gap,
            tangencyResidualBefore: boundary.tangencyResidual,
            tangencyResidualAfter: 0,
            endpointDisplacement: 0,
            fixed: false,
            dimensioned: false,
          ),
        );
      }
    }

    if (maxG1 > context.tangencyTolerance &&
        boundaries.any(
          (boundary) => boundary.kind == ArcRadiusBoundaryKind.tangent,
        )) {
      return ArcRadiusEditPlan.rejected(
        'A solução não preserva a tangência dentro da tolerância configurada.',
      );
    }

    final connectionTolerance = context.connectionTolerance;
    for (final boundary in boundaries) {
      if (boundary.fixed &&
          boundary.entity != null &&
          boundary.plannedDisplacement > connectionTolerance) {
        return ArcRadiusEditPlan.rejected(
          'A fronteira ${boundary.entity!.id} está fixada e não pode mover o contato.',
        );
      }
      if (boundary.dimensioned &&
          boundary.entity != null &&
          boundary.plannedDisplacement > connectionTolerance) {
        return ArcRadiusEditPlan.rejected(
          'A fronteira ${boundary.entity!.id} possui uma cota que impede mover o contato.',
        );
      }
    }

    final threshold = context.confirmationThreshold;
    return ArcRadiusEditPlan.success(
      arc: ArcRadiusGeometry(
        center: geometry.center,
        radius: radius,
        startAngle: geometry.startAngle,
        endAngle: geometry.endAngle,
      ),
      boundaries: plans,
      endpointUpdates: updates,
      affectedEntityIds: {arc.id, ...updates.keys},
      maxEndpointDisplacement: maxMove,
      maxCoincidenceResidual: maxC0,
      maxTangencyResidual: maxG1,
      requiresConfirmation: threshold != null && maxMove > threshold,
      previousRadius: oldRadius,
      requestedRadius: radius,
      diagnostic: maxG1 > context.tangencyTolerance
          ? 'Contato C0 preservado; tangência G1 não solicitada '
                '(resíduo ${maxG1.toStringAsExponential(3)}).'
          : null,
    );
  }
}

class _BoundaryCandidate {
  _BoundaryCandidate({
    required this.endpoint,
    required this.entity,
    required this.entityEndpoint,
    required this.attached,
    required this.other,
    required this.gap,
    required this.tangencyResidual,
    required this.kind,
    required this.ambiguous,
    required this.fixed,
    required this.dimensioned,
  });

  final String endpoint;
  final SketchEntity? entity;
  final String? entityEndpoint;
  final SketchVector? attached;
  final SketchVector? other;
  final double gap;
  final double tangencyResidual;
  final ArcRadiusBoundaryKind kind;
  final bool ambiguous;
  final bool fixed;
  final bool dimensioned;
  double plannedDisplacement = 0;
}

class _EndpointCandidate {
  const _EndpointCandidate(this.entity, this.endpoint, this.point, this.other);
  final SketchEntity entity;
  final String endpoint;
  final SketchVector point;
  final SketchVector? other;
}

class _SolvedGeometry {
  const _SolvedGeometry({
    required this.center,
    required this.startAngle,
    required this.endAngle,
    required this.contacts,
  });
  final SketchVector center;
  final double startAngle;
  final double endAngle;
  final List<SketchVector> contacts;
}

extension on SketchVector {
  bool get _finite => x.isFinite && y.isFinite && z.isFinite;
  double get length2d => math.sqrt(x * x + y * y);
  double distanceTo(SketchVector other) {
    final delta = this - other;
    return math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z);
  }
}

double? _number(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

SketchVector? _vector(Object? value) {
  if (value is! List ||
      value.length != 3 ||
      value.any((item) => item is! num || !item.isFinite)) {
    return null;
  }
  return SketchVector(
    (value[0] as num).toDouble(),
    (value[1] as num).toDouble(),
    (value[2] as num).toDouble(),
  );
}

bool _finiteContext(ArcRadiusEditContext context) {
  bool valid(double value) => value.isFinite && value >= 0;
  return valid(context.connectionTolerance) &&
      valid(context.gapTolerance) &&
      valid(context.tangencyTolerance) &&
      (context.frontierTolerance == null ||
          valid(context.frontierTolerance!)) &&
      (context.confirmationThreshold == null ||
          valid(context.confirmationThreshold!));
}

SketchVector _pointAt(SketchVector center, double radius, double angle) =>
    SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
      center.z,
    );

List<_EndpointCandidate> _endpoints(SketchEntity entity) {
  if (entity is SketchLine) {
    final start = _vector(entity.parameters['start']);
    final end = _vector(entity.parameters['end']);
    if (start == null || end == null) {
      return const [];
    }
    return [
      _EndpointCandidate(entity, 'start', start, end),
      _EndpointCandidate(entity, 'end', end, start),
    ];
  }
  if (entity is SketchSpline) {
    final raw =
        entity.parameters['sampledPoints'] ?? entity.parameters['points'];
    if (raw is! List || raw.length < 2) return const [];
    final points = raw.map(_vector).toList();
    if (points.any((point) => point == null)) return const [];
    final values = points.cast<SketchVector>();
    return [
      _EndpointCandidate(entity, 'start', values.first, values[1]),
      _EndpointCandidate(entity, 'end', values.last, values[values.length - 2]),
    ];
  }
  return const [];
}

_BoundaryCandidate _findBoundary({
  required SketchArc arc,
  required String endpoint,
  required SketchVector center,
  required SketchVector point,
  required ArcRadiusEditContext context,
}) {
  final tolerance =
      context.frontierTolerance ??
      math.max(.25, (_number(arc.parameters['radius']) ?? 0) * .01);
  final candidates = <({_EndpointCandidate candidate, double distance})>[];
  for (final entity in context.entities) {
    if (entity.id == arc.id ||
        !entity.visible ||
        entity.construction ||
        entity.reference) {
      continue;
    }
    for (final candidate in _endpoints(entity)) {
      final distance = candidate.point.distanceTo(point);
      if (distance <= tolerance) {
        candidates.add((candidate: candidate, distance: distance));
      }
    }
  }
  candidates.sort((a, b) {
    final distance = a.distance.compareTo(b.distance);
    if (distance != 0) return distance;
    final entity = a.candidate.entity.id.compareTo(b.candidate.entity.id);
    if (entity != 0) return entity;
    return a.candidate.endpoint.compareTo(b.candidate.endpoint);
  });
  final exactCandidates = candidates
      .where((item) => item.distance <= context.connectionTolerance)
      .toList();
  if (candidates.length != 1 && exactCandidates.length == 1) {
    candidates
      ..clear()
      ..add(exactCandidates.single);
  }
  if (candidates.length != 1) {
    return _BoundaryCandidate(
      endpoint: endpoint,
      entity: null,
      entityEndpoint: null,
      attached: null,
      other: null,
      gap: candidates.isEmpty ? 0 : candidates.first.distance,
      tangencyResidual: double.infinity,
      kind: candidates.isEmpty
          ? ArcRadiusBoundaryKind.free
          : ArcRadiusBoundaryKind.ambiguous,
      ambiguous: candidates.isNotEmpty,
      fixed: false,
      dimensioned: false,
    );
  }
  final selected = candidates.single;
  final candidate = selected.candidate;
  final gap = selected.distance;
  final tangentResidual = _tangencyResidual(center, point, candidate);
  final fixed =
      candidate.entity.locked ||
      _hasEndpointConstraint(
        context.constraints,
        candidate.entity.id,
        candidate.endpoint,
        const {SketchConstraintType.fixed, SketchConstraintType.lock},
      );
  final dimensioned = _hasEndpointConstraint(
    context.constraints,
    candidate.entity.id,
    candidate.endpoint,
    const {
      SketchConstraintType.distance,
      SketchConstraintType.angle,
      SketchConstraintType.drivingDimension,
      SketchConstraintType.radius,
      SketchConstraintType.diameter,
    },
  );
  final tangent =
      tangentResidual <= context.tangencyTolerance ||
      _hasPairConstraint(
        context.constraints,
        SketchConstraintType.tangent,
        arc.id,
        candidate.entity.id,
      );
  final coincident =
      gap <= context.connectionTolerance ||
      _hasEndpointConstraint(
        context.constraints,
        candidate.entity.id,
        candidate.endpoint,
        const {SketchConstraintType.coincident},
      );
  final kind = gap > context.connectionTolerance
      ? ArcRadiusBoundaryKind.gap
      : fixed
      ? ArcRadiusBoundaryKind.fixed
      : dimensioned
      ? ArcRadiusBoundaryKind.dimensioned
      : tangent
      ? ArcRadiusBoundaryKind.tangent
      : coincident
      ? ArcRadiusBoundaryKind.coincident
      : ArcRadiusBoundaryKind.free;
  return _BoundaryCandidate(
    endpoint: endpoint,
    entity: candidate.entity,
    entityEndpoint: candidate.endpoint,
    attached: candidate.point,
    other: candidate.other,
    gap: gap,
    tangencyResidual: tangentResidual,
    kind: kind,
    ambiguous: false,
    fixed: fixed,
    dimensioned: dimensioned,
  );
}

double _tangencyResidual(
  SketchVector center,
  SketchVector point,
  _EndpointCandidate candidate,
) {
  final other = candidate.other;
  if (other == null) return double.infinity;
  final direction = point - other;
  final radial = point - center;
  final dl = direction.length2d, rl = radial.length2d;
  if (dl <= 1e-12 || rl <= 1e-12) return double.infinity;
  return (direction.x * radial.x + direction.y * radial.y).abs() / (dl * rl);
}

bool _hasEndpointConstraint(
  Iterable<SketchConstraint> constraints,
  String entityId,
  String endpoint,
  Set<SketchConstraintType> types,
) => constraints.any(
  (constraint) =>
      constraint.enabled &&
      !constraint.suppressed &&
      types.contains(constraint.type) &&
      constraint.references.any(
        (reference) =>
            reference == entityId || reference == '$entityId:$endpoint',
      ),
);

bool _hasEntityConstraint(
  Iterable<SketchConstraint> constraints,
  String entityId,
  Set<SketchConstraintType> types,
) => constraints.any(
  (constraint) =>
      constraint.enabled &&
      !constraint.suppressed &&
      types.contains(constraint.type) &&
      constraint.references.any(
        (reference) =>
            reference == entityId || reference.startsWith('$entityId:'),
      ),
);

bool _hasPairConstraint(
  Iterable<SketchConstraint> constraints,
  SketchConstraintType type,
  String first,
  String second,
) => constraints.any(
  (constraint) =>
      constraint.enabled &&
      !constraint.suppressed &&
      constraint.type == type &&
      constraint.references.any(
        (reference) => reference == first || reference.startsWith('$first:'),
      ) &&
      constraint.references.any(
        (reference) => reference == second || reference.startsWith('$second:'),
      ),
);

_SolvedGeometry? _keepEndpoints({
  required SketchVector center,
  required double oldRadius,
  required double oldStart,
  required double oldEnd,
  required double radius,
}) {
  final start = _pointAt(center, oldRadius, oldStart);
  final end = _pointAt(center, oldRadius, oldEnd);
  final dx = end.x - start.x, dy = end.y - start.y;
  final chord = math.sqrt(dx * dx + dy * dy);
  if (chord <= 1e-12 || chord > 2 * radius + 1e-9) return null;
  final height = math.sqrt(math.max(0, radius * radius - chord * chord / 4));
  final mid = SketchVector(
    (start.x + end.x) / 2,
    (start.y + end.y) / 2,
    start.z,
  );
  final candidates = [
    SketchVector(
      mid.x - dy / chord * height,
      mid.y + dx / chord * height,
      mid.z,
    ),
    SketchVector(
      mid.x + dy / chord * height,
      mid.y - dx / chord * height,
      mid.z,
    ),
  ];
  candidates.sort(
    (a, b) => a.distanceTo(center).compareTo(b.distanceTo(center)),
  );
  final next = candidates.first;
  final angles = _orientedAngles(next, start, end, oldStart, oldEnd);
  return _SolvedGeometry(
    center: next,
    startAngle: angles.$1,
    endAngle: angles.$2,
    contacts: [start, end],
  );
}

_SolvedGeometry? _solveTwoLines({
  required SketchVector center,
  required double oldStart,
  required double oldEnd,
  required double radius,
  required List<_BoundaryCandidate> boundaries,
  required double tangencyTolerance,
}) {
  final first = boundaries[0], second = boundaries[1];
  if (first.entity is! SketchLine || second.entity is! SketchLine) return null;
  if (first.tangencyResidual > tangencyTolerance ||
      second.tangencyResidual > tangencyTolerance) {
    return null;
  }
  final n0 = _normal(first), n1 = _normal(second);
  if (n0 == null || n1 == null) return null;
  final p0 = first.attached!, p1 = second.attached!;
  final determinant = n0.cross2d(n1);
  if (determinant.abs() <= 1e-8) return null;
  _SolvedGeometry? best;
  var scoreBest = double.infinity;
  for (final sign0 in [-1.0, 1.0]) {
    for (final sign1 in [-1.0, 1.0]) {
      final d0 = n0.dot2d(p0) + sign0 * radius;
      final d1 = n1.dot2d(p1) + sign1 * radius;
      final next = SketchVector(
        (d0 * n1.y - n0.y * d1) / determinant,
        (n0.x * d1 - d0 * n1.x) / determinant,
        center.z,
      );
      if (!next._finite) continue;
      final contacts = [
        next - n0.scale(sign0 * radius),
        next - n1.scale(sign1 * radius),
      ];
      final angles = _orientedAngles(
        next,
        contacts[0],
        contacts[1],
        oldStart,
        oldEnd,
      );
      final sweep = (angles.$2 - angles.$1).abs();
      if (sweep <= 1e-8 || sweep > 2 * math.pi + 1e-8) continue;
      final score =
          next.distanceTo(center) * .1 +
          contacts[0].distanceTo(p0) +
          contacts[1].distanceTo(p1) +
          (sweep - (oldEnd - oldStart).abs()).abs() * radius;
      if (score < scoreBest) {
        scoreBest = score;
        best = _SolvedGeometry(
          center: next,
          startAngle: angles.$1,
          endAngle: angles.$2,
          contacts: contacts,
        );
      }
    }
  }
  return best;
}

_SolvedGeometry? _solveOneLine({
  required SketchVector center,
  required double oldStart,
  required double oldEnd,
  required double radius,
  required _BoundaryCandidate matched,
  required List<SketchVector> oldEndpoints,
  required double tangencyTolerance,
}) {
  if (matched.entity is! SketchLine || matched.attached == null) return null;
  if (matched.tangencyResidual > tangencyTolerance) {
    return _solveOneLineByContact(
      center: center,
      oldStart: oldStart,
      oldEnd: oldEnd,
      radius: radius,
      matched: matched,
    );
  }
  final normal = _normal(matched);
  if (normal == null) return null;
  final attachedIndex = matched.endpoint == 'start' ? 0 : 1;
  final freeIndex = 1 - attachedIndex;
  final free = oldEndpoints[freeIndex];
  final sign = normal.dot2d(center - matched.attached!) >= 0 ? 1.0 : -1.0;
  final offset = normal.dot2d(matched.attached!) + sign * radius;
  final base = SketchVector(normal.x * offset, normal.y * offset, center.z);
  final tangent = SketchVector(-normal.y, normal.x);
  final delta = free - base;
  final along = delta.dot2d(tangent);
  final perpendicular = delta.dot2d(normal);
  final remaining = radius * radius - perpendicular * perpendicular;
  if (remaining < -1e-9) return null;
  final height = math.sqrt(math.max(0, remaining));
  _SolvedGeometry? best;
  var scoreBest = double.infinity;
  for (final parameter in [along - height, along + height]) {
    final next = base + tangent.scale(parameter);
    final contact = next - normal.scale(sign * radius);
    final contacts = attachedIndex == 0 ? [contact, free] : [free, contact];
    final angles = _orientedAngles(
      next,
      contacts[0],
      contacts[1],
      oldStart,
      oldEnd,
    );
    final sweep = (angles.$2 - angles.$1).abs();
    if (sweep <= 1e-8 || sweep > 2 * math.pi + 1e-8) continue;
    final score =
        next.distanceTo(center) * .1 +
        contact.distanceTo(matched.attached!) +
        (sweep - (oldEnd - oldStart).abs()).abs() * radius;
    if (score < scoreBest) {
      scoreBest = score;
      best = _SolvedGeometry(
        center: next,
        startAngle: angles.$1,
        endAngle: angles.$2,
        contacts: contacts,
      );
    }
  }
  return best;
}

_SolvedGeometry? _solveOneLineByContact({
  required SketchVector center,
  required double oldStart,
  required double oldEnd,
  required double radius,
  required _BoundaryCandidate matched,
}) {
  final normal = _normal(matched);
  final attached = matched.attached;
  final other = matched.other;
  if (normal == null || attached == null || other == null) return null;
  final offset = normal.dot2d(attached);
  final signedDistance = offset - normal.dot2d(center);
  final distance = signedDistance.abs();
  if (distance > radius + 1e-9) return null;
  final foot = center + normal.scale(signedDistance);
  final tangent = SketchVector(-normal.y, normal.x);
  final height = math.sqrt(math.max(0, radius * radius - distance * distance));
  final attachedIndex = matched.endpoint == 'start' ? 0 : 1;
  final freeIndex = 1 - attachedIndex;
  final freeAngle = freeIndex == 0 ? oldStart : oldEnd;
  final free = _pointAt(center, radius, freeAngle);
  _SolvedGeometry? best;
  var bestScore = double.infinity;
  for (final sign in [-1.0, 1.0]) {
    final contact = foot + tangent.scale(sign * height);
    final contacts = attachedIndex == 0 ? [contact, free] : [free, contact];
    final angles = _orientedAngles(
      center,
      contacts[0],
      contacts[1],
      oldStart,
      oldEnd,
    );
    final sweep = (angles.$2 - angles.$1).abs();
    if (sweep <= 1e-8 || sweep > 2 * math.pi + 1e-8) continue;
    final score =
        contact.distanceTo(attached) +
        (sweep - (oldEnd - oldStart).abs()).abs() * radius;
    if (score < bestScore) {
      bestScore = score;
      best = _SolvedGeometry(
        center: center,
        startAngle: angles.$1,
        endAngle: angles.$2,
        contacts: contacts,
      );
    }
  }
  return best;
}

SketchVector? _normal(_BoundaryCandidate boundary) {
  final direction = boundary.attached! - boundary.other!;
  final length = direction.length2d;
  if (length <= 1e-12 || !length.isFinite) return null;
  return SketchVector(-direction.y / length, direction.x / length);
}

(double, double) _orientedAngles(
  SketchVector center,
  SketchVector start,
  SketchVector end,
  double oldStart,
  double oldEnd,
) {
  final startAngle = math.atan2(start.y - center.y, start.x - center.x);
  var endAngle = math.atan2(end.y - center.y, end.x - center.x);
  if (oldEnd >= oldStart) {
    while (endAngle < startAngle) {
      endAngle += 2 * math.pi;
    }
  } else {
    while (endAngle > startAngle) {
      endAngle -= 2 * math.pi;
    }
  }
  return (startAngle, endAngle);
}

extension on SketchVector {
  double dot2d(SketchVector other) => x * other.x + y * other.y;
  double cross2d(SketchVector other) => x * other.y - y * other.x;
}
