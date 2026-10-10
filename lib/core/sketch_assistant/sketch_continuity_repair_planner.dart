import 'dart:math' as math;

import '../sketch_constraints/models/constraint_models.dart';
import '../sketch_editor/health/sketch_health_analyzer.dart';
import '../sketch_engine/entities/sketch_entities.dart';
import '../sketch_engine/models/sketch_models.dart';
import 'sketch_reconstruction.dart';

enum SketchContinuityRepairStatus { valid, requiresConfirmation, impossible }

enum SketchContinuityRepairAlternativeKind {
  moveFirstEndpoint,
  moveSecondEndpoint,
  moveBothEndpoints,
  extendFirstLine,
  trimFirstLine,
  extendSecondLine,
  trimSecondLine,
  preserveProtectedEndpoint,
}

class SketchContinuityRepairEndpointUpdate {
  const SketchContinuityRepairEndpointUpdate({
    required this.entityId,
    required this.endpoint,
    required this.before,
    required this.after,
    required this.displacementMillimeters,
    required this.operation,
  });

  final String entityId;
  final String endpoint;
  final SketchVector before;
  final SketchVector after;
  final double displacementMillimeters;
  final String operation;
}

class SketchContinuityRepairAdjacentEffect {
  const SketchContinuityRepairAdjacentEffect({
    required this.firstEntityId,
    required this.firstEndpoint,
    required this.secondEntityId,
    required this.secondEndpoint,
    required this.beforeGapMillimeters,
    required this.afterGapMillimeters,
    required this.beforeContinuity,
    required this.afterContinuity,
  });

  final String firstEntityId;
  final String firstEndpoint;
  final String secondEntityId;
  final String secondEndpoint;
  final double beforeGapMillimeters;
  final double afterGapMillimeters;
  final SketchContinuityLevel beforeContinuity;
  final SketchContinuityLevel afterContinuity;
}

/// One immutable repair alternative.  Alternatives are intentionally not
/// ranked or selected by the planner: an operator or a future preview must
/// choose explicitly after reviewing constraints and neighbour effects.
class SketchContinuityRepairAlternative {
  const SketchContinuityRepairAlternative({
    required this.kind,
    required this.status,
    required this.updates,
    required this.affectedEntityIds,
    required this.adjacentEffects,
    required this.maxDisplacementMillimeters,
    required this.c0ResidualMillimeters,
    required this.g1ResidualRadians,
    required this.diagnostics,
  });

  final SketchContinuityRepairAlternativeKind kind;
  final SketchContinuityRepairStatus status;
  final List<SketchContinuityRepairEndpointUpdate> updates;
  final List<String> affectedEntityIds;
  final List<SketchContinuityRepairAdjacentEffect> adjacentEffects;
  final double maxDisplacementMillimeters;
  final double c0ResidualMillimeters;
  final double? g1ResidualRadians;
  final List<String> diagnostics;

  bool get changesGeometry => updates.isNotEmpty;
}

/// Result of planning a single C0 repair.  This object contains no entity
/// references that can be mutated and has no Apply/Undo integration.
class SketchContinuityRepairPlan {
  const SketchContinuityRepairPlan({
    required this.firstEntityId,
    required this.secondEntityId,
    required this.status,
    required this.currentGapMillimeters,
    required this.connectionToleranceMillimeters,
    required this.repairGapToleranceMillimeters,
    required this.alternatives,
    required this.protectedEntityIds,
    required this.diagnostics,
  });

  final String firstEntityId;
  final String secondEntityId;
  final SketchContinuityRepairStatus status;
  final double currentGapMillimeters;
  final double connectionToleranceMillimeters;
  final double repairGapToleranceMillimeters;
  final List<SketchContinuityRepairAlternative> alternatives;
  final List<String> protectedEntityIds;
  final List<String> diagnostics;

  bool get canRepair =>
      status != SketchContinuityRepairStatus.impossible &&
      alternatives.any(
        (alternative) =>
            alternative.status != SketchContinuityRepairStatus.impossible &&
            alternative.updates.isNotEmpty,
      );
}

/// Pure planner for C0 repairs.  It reuses Sketch Health's connection/gap
/// tolerances and only proposes immutable endpoint changes.  It never invokes
/// the solver, writes an entity, creates a constraint, or records history.
class SketchContinuityRepairPlanner {
  const SketchContinuityRepairPlanner({
    this.health = const SketchHealthAnalyzer(),
    this.diagnostic = const SketchContinuityDiagnostic(),
  });

  final SketchHealthAnalyzer health;
  final SketchContinuityDiagnostic diagnostic;

  SketchContinuityRepairPlan plan(
    SketchContinuityJoinDiagnostic selected, {
    required Map<String, SketchEntity> entities,
    Iterable<SketchConstraint> constraints = const <SketchConstraint>[],
  }) {
    final first = entities[selected.first.entityId];
    final second = entities[selected.second.entityId];
    final base = <String>[];
    if (first == null || second == null) {
      base.add('A junção referencia entidades ausentes.');
      return _impossible(selected, base);
    }
    if (first.id == second.id) {
      base.add('Uma junção não pode usar a mesma entidade duas vezes.');
      return _impossible(selected, base);
    }
    final current = _currentJoin(first, second, constraints, selected);
    if (current == null) {
      base.add('A junção selecionada está obsoleta ou mudou de endpoint.');
      return _impossible(selected, base);
    }
    final gap = current.gapMillimeters;
    if (gap <= health.connectionTolerance) {
      return SketchContinuityRepairPlan(
        firstEntityId: current.first.entityId,
        secondEntityId: current.second.entityId,
        status: SketchContinuityRepairStatus.valid,
        currentGapMillimeters: gap,
        connectionToleranceMillimeters: health.connectionTolerance,
        repairGapToleranceMillimeters: health.gapTolerance,
        alternatives: const <SketchContinuityRepairAlternative>[],
        protectedEntityIds: const <String>[],
        diagnostics: [
          'A junção já está coincidente dentro de '
              '${health.connectionTolerance.toStringAsFixed(6)} mm.',
        ],
      );
    }
    if (gap > health.gapTolerance) {
      base.add(
        'Gap de ${gap.toStringAsFixed(3)} mm excede a tolerância de reparo '
        'existente (${health.gapTolerance.toStringAsFixed(3)} mm).',
      );
      return _impossible(current, base);
    }

    final allConstraints = constraints.toList(growable: false);
    final firstGuard = _guard(first, current.first.name, allConstraints);
    final secondGuard = _guard(second, current.second.name, allConstraints);
    final protectedIds = <String>[
      if (firstGuard.protected) first.id,
      if (secondGuard.protected) second.id,
    ]..sort();
    final alternatives = <SketchContinuityRepairAlternative>[];
    final targetFirst = current.second.point;
    final targetSecond = current.first.point;

    if (!firstGuard.protected) {
      final kind = first is SketchLine
          ? _lineOperation(first, current.first.name, targetFirst)
          : SketchContinuityRepairAlternativeKind.moveFirstEndpoint;
      _addEndpointAlternatives(
        alternatives,
        entity: first,
        endpoint: current.first.name,
        target: targetFirst,
        otherEntity: second,
        otherEndpoint: current.second.name,
        kind: kind,
        entities: entities,
        constraints: allConstraints,
      );
    }
    if (!secondGuard.protected) {
      final kind = second is SketchLine
          ? _lineOperation(second, current.second.name, targetSecond)
          : SketchContinuityRepairAlternativeKind.moveSecondEndpoint;
      _addEndpointAlternatives(
        alternatives,
        entity: second,
        endpoint: current.second.name,
        target: targetSecond,
        otherEntity: first,
        otherEndpoint: current.first.name,
        kind: kind,
        entities: entities,
        constraints: allConstraints,
      );
    }

    if (!firstGuard.protected && !secondGuard.protected) {
      final midpoint = SketchVector(
        (current.first.point.x + current.second.point.x) / 2,
        (current.first.point.y + current.second.point.y) / 2,
        (current.first.point.z + current.second.point.z) / 2,
      );
      _addBothEndpointAlternative(
        alternatives,
        first: first,
        firstEndpoint: current.first.name,
        second: second,
        secondEndpoint: current.second.name,
        target: midpoint,
        entities: entities,
        constraints: allConstraints,
      );
    }

    final diagnostics = <String>[
      if (firstGuard.reasons.isNotEmpty)
        '${first.id}:${current.first.name} protegido por '
            '${firstGuard.reasons.join(', ')}.',
      if (secondGuard.reasons.isNotEmpty)
        '${second.id}:${current.second.name} protegido por '
            '${secondGuard.reasons.join(', ')}.',
      if (first is SketchSpline || second is SketchSpline)
        'Spline não é alterada sem avaliação de deformação dos pontos de controle.',
      ...base,
    ];
    if (alternatives.isEmpty) {
      diagnostics.add(
        'Nenhuma alternativa preserva a geometria e as relações existentes.',
      );
    }
    final hasViableAlternative = alternatives.any(
      (alternative) =>
          alternative.status != SketchContinuityRepairStatus.impossible,
    );
    final status = !hasViableAlternative
        ? SketchContinuityRepairStatus.impossible
        : SketchContinuityRepairStatus.requiresConfirmation;
    return SketchContinuityRepairPlan(
      firstEntityId: current.first.entityId,
      secondEntityId: current.second.entityId,
      status: status,
      currentGapMillimeters: gap,
      connectionToleranceMillimeters: health.connectionTolerance,
      repairGapToleranceMillimeters: health.gapTolerance,
      alternatives: List.unmodifiable(alternatives),
      protectedEntityIds: List.unmodifiable(protectedIds),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  SketchContinuityRepairPlan _impossible(
    SketchContinuityJoinDiagnostic join,
    List<String> diagnostics,
  ) => SketchContinuityRepairPlan(
    firstEntityId: join.first.entityId,
    secondEntityId: join.second.entityId,
    status: SketchContinuityRepairStatus.impossible,
    currentGapMillimeters: join.gapMillimeters,
    connectionToleranceMillimeters: health.connectionTolerance,
    repairGapToleranceMillimeters: health.gapTolerance,
    alternatives: const <SketchContinuityRepairAlternative>[],
    protectedEntityIds: const <String>[],
    diagnostics: List.unmodifiable(diagnostics),
  );

  SketchContinuityJoinDiagnostic? _currentJoin(
    SketchEntity first,
    SketchEntity second,
    Iterable<SketchConstraint> constraints,
    SketchContinuityJoinDiagnostic selected,
  ) {
    final joins = diagnostic.analyze([
      first,
      second,
    ], constraints: constraints).joins;
    for (final join in joins) {
      final sameDirection =
          join.first.entityId == selected.first.entityId &&
          join.second.entityId == selected.second.entityId &&
          join.first.name == selected.first.name &&
          join.second.name == selected.second.name;
      final reverseDirection =
          join.first.entityId == selected.second.entityId &&
          join.second.entityId == selected.first.entityId &&
          join.first.name == selected.second.name &&
          join.second.name == selected.first.name;
      if (!sameDirection && !reverseDirection) continue;
      final firstDistance = reverseDirection
          ? _distance(join.first.point, selected.second.point)
          : _distance(join.first.point, selected.first.point);
      final secondDistance = reverseDirection
          ? _distance(join.second.point, selected.first.point)
          : _distance(join.second.point, selected.second.point);
      if (firstDistance > health.connectionTolerance ||
          secondDistance > health.connectionTolerance) {
        return null;
      }
      return join;
    }
    return null;
  }

  void _addEndpointAlternatives(
    List<SketchContinuityRepairAlternative> output, {
    required SketchEntity entity,
    required String endpoint,
    required SketchVector target,
    required SketchEntity otherEntity,
    required String otherEndpoint,
    required SketchContinuityRepairAlternativeKind kind,
    required Map<String, SketchEntity> entities,
    required List<SketchConstraint> constraints,
  }) {
    final proposed = _moveEndpoint(entity, endpoint, target);
    if (proposed == null) return;
    final before = _endpoint(entity, endpoint);
    final displacement = _distance(before, target);
    output.add(
      _evaluateAlternative(
        kind: kind,
        proposed: {entity.id: proposed},
        updates: [
          SketchContinuityRepairEndpointUpdate(
            entityId: entity.id,
            endpoint: endpoint,
            before: before,
            after: target,
            displacementMillimeters: displacement,
            operation: kind.name,
          ),
        ],
        entities: entities,
        constraints: constraints,
        selectedPair: {entity.id, otherEntity.id},
        diagnostics: [
          'Contato ${entity.id}:$endpoint → '
              '${otherEntity.id}:$otherEndpoint.',
        ],
      ),
    );
  }

  void _addBothEndpointAlternative(
    List<SketchContinuityRepairAlternative> output, {
    required SketchEntity first,
    required String firstEndpoint,
    required SketchEntity second,
    required String secondEndpoint,
    required SketchVector target,
    required Map<String, SketchEntity> entities,
    required List<SketchConstraint> constraints,
  }) {
    final proposedFirst = _moveEndpoint(first, firstEndpoint, target);
    final proposedSecond = _moveEndpoint(second, secondEndpoint, target);
    if (proposedFirst == null || proposedSecond == null) return;
    output.add(
      _evaluateAlternative(
        kind: SketchContinuityRepairAlternativeKind.moveBothEndpoints,
        proposed: {first.id: proposedFirst, second.id: proposedSecond},
        updates: [
          SketchContinuityRepairEndpointUpdate(
            entityId: first.id,
            endpoint: firstEndpoint,
            before: _endpoint(first, firstEndpoint),
            after: target,
            displacementMillimeters: _distance(
              _endpoint(first, firstEndpoint),
              target,
            ),
            operation: 'moveBothEndpoints',
          ),
          SketchContinuityRepairEndpointUpdate(
            entityId: second.id,
            endpoint: secondEndpoint,
            before: _endpoint(second, secondEndpoint),
            after: target,
            displacementMillimeters: _distance(
              _endpoint(second, secondEndpoint),
              target,
            ),
            operation: 'moveBothEndpoints',
          ),
        ],
        entities: entities,
        constraints: constraints,
        selectedPair: {first.id, second.id},
        diagnostics: ['Ambos endpoints serão ajustados ao ponto médio.'],
      ),
    );
  }

  SketchContinuityRepairAlternative _evaluateAlternative({
    required SketchContinuityRepairAlternativeKind kind,
    required Map<String, SketchEntity> proposed,
    required List<SketchContinuityRepairEndpointUpdate> updates,
    required Map<String, SketchEntity> entities,
    required List<SketchConstraint> constraints,
    required Set<String> selectedPair,
    required List<String> diagnostics,
  }) {
    final virtualEntities = <SketchEntity>[
      for (final entity in entities.values) proposed[entity.id] ?? entity,
    ];
    final before = diagnostic.analyze(
      entities.values,
      constraints: constraints,
    );
    final after = diagnostic.analyze(virtualEntities, constraints: constraints);
    final selectedAfter = after.joins.firstWhere(
      (join) =>
          selectedPair.contains(join.first.entityId) &&
          selectedPair.contains(join.second.entityId),
      orElse: () => throw StateError('repair candidate lost its selected join'),
    );
    final selectedBefore = before.joins.firstWhere(
      (join) =>
          selectedPair.contains(join.first.entityId) &&
          selectedPair.contains(join.second.entityId),
      orElse: () => selectedAfter,
    );
    final effects = <SketchContinuityRepairAdjacentEffect>[];
    for (final beforeJoin in before.joins) {
      if (!beforeJoin.nearby ||
          !selectedPair.contains(beforeJoin.first.entityId) &&
              !selectedPair.contains(beforeJoin.second.entityId)) {
        continue;
      }
      if (selectedPair.contains(beforeJoin.first.entityId) &&
          selectedPair.contains(beforeJoin.second.entityId)) {
        continue;
      }
      final afterJoin = after.joins.firstWhere(
        (join) =>
            join.first.entityId == beforeJoin.first.entityId &&
            join.second.entityId == beforeJoin.second.entityId &&
            join.first.name == beforeJoin.first.name &&
            join.second.name == beforeJoin.second.name,
        orElse: () => beforeJoin,
      );
      effects.add(
        SketchContinuityRepairAdjacentEffect(
          firstEntityId: beforeJoin.first.entityId,
          firstEndpoint: beforeJoin.first.name,
          secondEntityId: beforeJoin.second.entityId,
          secondEndpoint: beforeJoin.second.name,
          beforeGapMillimeters: beforeJoin.gapMillimeters,
          afterGapMillimeters: afterJoin.gapMillimeters,
          beforeContinuity: beforeJoin.continuity,
          afterContinuity: afterJoin.continuity,
        ),
      );
    }
    final affected = <String>{
      ...proposed.keys,
      for (final effect in effects) effect.firstEntityId,
      for (final effect in effects) effect.secondEntityId,
    }.toList()..sort();
    final maxDisplacement = updates.fold<double>(
      0,
      (value, update) => math.max(value, update.displacementMillimeters),
    );
    final breaksExternalConnection = effects.any(
      (effect) =>
          effect.beforeContinuity != SketchContinuityLevel.disconnected &&
          effect.afterContinuity == SketchContinuityLevel.disconnected,
    );
    final alternativeStatus = breaksExternalConnection
        ? SketchContinuityRepairStatus.impossible
        : SketchContinuityRepairStatus.requiresConfirmation;
    return SketchContinuityRepairAlternative(
      kind: kind,
      status: alternativeStatus,
      updates: List.unmodifiable(updates),
      affectedEntityIds: List.unmodifiable(affected),
      adjacentEffects: List.unmodifiable(effects),
      maxDisplacementMillimeters: maxDisplacement,
      c0ResidualMillimeters: selectedAfter.gapMillimeters,
      g1ResidualRadians: selectedAfter.tangentAngleRadians,
      diagnostics: List.unmodifiable([
        ...diagnostics,
        'Resíduo C0 após proposta: '
            '${selectedAfter.gapMillimeters.toStringAsFixed(6)} mm.',
        if (selectedAfter.tangentAngleRadians != null)
          'Resíduo G1 após proposta: '
              '${selectedAfter.tangentAngleRadians!.toStringAsFixed(6)} rad.',
        if (selectedBefore.measuredG1 && !selectedAfter.measuredG1)
          'A proposta perde a tangência G1 medida na junção.',
        if (breaksExternalConnection)
          'A proposta rompe uma conexão C0/G1 externa existente.',
      ]),
    );
  }

  SketchContinuityRepairAlternativeKind _lineOperation(
    SketchLine line,
    String endpoint,
    SketchVector target,
  ) {
    final start = SketchVector.fromJson(line.parameters['start']);
    final end = SketchVector.fromJson(line.parameters['end']);
    final fixed = endpoint == 'start' ? start : end;
    final other = endpoint == 'start' ? end : start;
    final direction = other - fixed;
    final length2 = direction.dot(direction);
    if (length2 <= 1e-24) {
      return endpoint == 'start'
          ? SketchContinuityRepairAlternativeKind.trimFirstLine
          : SketchContinuityRepairAlternativeKind.trimSecondLine;
    }
    final projection = (target - fixed).dot(direction) / length2;
    final extension = projection < 0 || projection > 1;
    if (endpoint == 'start') {
      return extension
          ? SketchContinuityRepairAlternativeKind.extendFirstLine
          : SketchContinuityRepairAlternativeKind.trimFirstLine;
    }
    return extension
        ? SketchContinuityRepairAlternativeKind.extendSecondLine
        : SketchContinuityRepairAlternativeKind.trimSecondLine;
  }

  SketchVector _endpoint(SketchEntity entity, String endpoint) {
    if (entity is SketchLine) {
      return SketchVector.fromJson(entity.parameters[endpoint]);
    }
    if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final angle = (entity.parameters['${endpoint}Angle'] as num).toDouble();
      return SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
        center.z,
      );
    }
    final raw =
        entity.parameters['sampledPoints'] ?? entity.parameters['points'];
    final samples = (raw as List).whereType<List>().map(SketchVector.fromJson);
    return endpoint == 'start' ? samples.first : samples.last;
  }

  SketchEntity? _moveEndpoint(
    SketchEntity entity,
    String endpoint,
    SketchVector target,
  ) {
    if (entity is SketchSpline) return null;
    if (entity is SketchLine) {
      final start = SketchVector.fromJson(entity.parameters['start']);
      final end = SketchVector.fromJson(entity.parameters['end']);
      final proposedStart = endpoint == 'start' ? target : start;
      final proposedEnd = endpoint == 'end' ? target : end;
      final delta = proposedEnd - proposedStart;
      if (delta.dot(delta) <= 1e-24) return null;
      return SketchLine(proposedStart, proposedEnd, id: entity.id);
    }
    if (entity is SketchArc) {
      final center = SketchVector.fromJson(entity.parameters['center']);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final startAngle = (entity.parameters['startAngle'] as num).toDouble();
      final endAngle = (entity.parameters['endAngle'] as num).toDouble();
      final targetRadius = _distance(target, center);
      if (!radius.isFinite ||
          targetRadius == double.infinity ||
          (targetRadius - radius).abs() > health.connectionTolerance) {
        return null;
      }
      final rawAngle = math.atan2(target.y - center.y, target.x - center.x);
      final referenceAngle = endpoint == 'start' ? startAngle : endAngle;
      final newAngle =
          rawAngle +
          2 * math.pi * ((referenceAngle - rawAngle) / (2 * math.pi)).round();
      final proposedStart = endpoint == 'start' ? newAngle : startAngle;
      final proposedEnd = endpoint == 'end' ? newAngle : endAngle;
      final oldSweep = endAngle - startAngle;
      final newSweep = proposedEnd - proposedStart;
      if (newSweep.abs() <= 1e-9 ||
          newSweep.abs() > 2 * math.pi + 1e-6 ||
          oldSweep.sign != newSweep.sign) {
        return null;
      }
      return SketchArc(
        center,
        radius,
        proposedStart,
        proposedEnd,
        id: entity.id,
      );
    }
    return null;
  }

  _EndpointGuard _guard(
    SketchEntity entity,
    String endpoint,
    List<SketchConstraint> constraints,
  ) {
    final reasons = <String>[];
    if (entity.locked ||
        entity.reference ||
        entity.construction ||
        !entity.visible ||
        entity.metadata['reconstructionHidden'] == true ||
        entity.metadata['repairProtected'] == true) {
      reasons.add('entidade protegida');
    }
    for (final constraint in constraints.where(
      (candidate) => _references(candidate, entity.id, endpoint),
    )) {
      switch (constraint.type) {
        case SketchConstraintType.fixed:
        case SketchConstraintType.lock:
          reasons.add('${constraint.type.name} ${constraint.id}');
        case SketchConstraintType.distance:
        case SketchConstraintType.radius:
        case SketchConstraintType.diameter:
        case SketchConstraintType.angle:
        case SketchConstraintType.offset:
        case SketchConstraintType.drivingDimension:
        case SketchConstraintType.drivenDimension:
          reasons.add('cota ${constraint.id}');
        default:
          reasons.add('${constraint.type.name} ${constraint.id}');
      }
    }
    return _EndpointGuard(
      protected: reasons.isNotEmpty,
      reasons: reasons.toSet().toList()..sort(),
    );
  }

  bool _references(
    SketchConstraint constraint,
    String entityId,
    String endpoint,
  ) {
    return constraint.references.any(
      (reference) =>
          reference == entityId ||
          reference == '$entityId:$endpoint' ||
          reference.startsWith('$entityId:'),
    );
  }

  double _distance(SketchVector first, SketchVector second) {
    final delta = first - second;
    return math.sqrt(delta.dot(delta));
  }
}

class _EndpointGuard {
  const _EndpointGuard({required this.protected, required this.reasons});

  final bool protected;
  final List<String> reasons;
}
