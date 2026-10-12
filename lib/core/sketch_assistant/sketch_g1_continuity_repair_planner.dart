import 'dart:convert';
import 'dart:math' as math;

import '../sketch_constraints/models/constraint_models.dart';
import '../sketch_editor/health/sketch_health_analyzer.dart';
import '../sketch_engine/entities/sketch_entities.dart';
import '../sketch_engine/models/sketch_models.dart';
import 'sketch_continuity_repair_planner.dart';
import 'sketch_reconstruction.dart';

extension on SketchContinuityJoinDiagnostic {
  String get firstEntityId => first.entityId;
  String get secondEntityId => second.entityId;
}

/// The geometric choices supported by the first G1 planner.  Each choice
/// preserves one of the two contacts and moves only the geometry named by the
/// alternative; no choice is ranked or applied by this package.
enum SketchG1RepairAlternativeKind {
  lineArcPreserveLineContact,
  lineArcPreserveArcContact,
  arcArcPreserveFirstContact,
  arcArcPreserveSecondContact,
}

/// An immutable geometry snapshot prepared for a future transactional Apply.
/// It contains the complete entity JSON, so metadata and identity survive the
/// round trip while the planner itself remains independent of a SketchEngine.
class SketchG1GeometryUpdate {
  SketchG1GeometryUpdate({
    required this.entityId,
    required this.entityType,
    required Map<String, dynamic> before,
    required Map<String, dynamic> after,
    required this.displacementMillimeters,
    required this.operation,
  }) : beforeJson = _freezeMap(before),
       afterJson = _freezeMap(after);

  final String entityId;
  final SketchEntityType entityType;
  final Map<String, dynamic> beforeJson;
  final Map<String, dynamic> afterJson;
  final double displacementMillimeters;
  final String operation;

  /// Materializes a detached copy for inspection or a future transaction.
  /// Mutating the returned object cannot mutate this plan.
  SketchEntity get proposedEntity =>
      SketchEntity.fromJson(_mutableMap(afterJson));

  SketchEntity get originalEntity =>
      SketchEntity.fromJson(_mutableMap(beforeJson));
}

/// One mathematically checked, but not yet applied, G1 alternative.
class SketchG1RepairAlternative {
  SketchG1RepairAlternative({
    required this.kind,
    required this.status,
    required updates,
    required affectedEntityIds,
    required this.beforeGapMillimeters,
    required this.afterGapMillimeters,
    required this.beforeG1ResidualRadians,
    required this.afterG1ResidualRadians,
    required this.maxDisplacementMillimeters,
    required diagnostics,
  }) : updates = List.unmodifiable(updates),
       affectedEntityIds = List.unmodifiable(affectedEntityIds),
       diagnostics = List.unmodifiable(diagnostics);

  final SketchG1RepairAlternativeKind kind;
  final SketchContinuityRepairStatus status;
  final List<SketchG1GeometryUpdate> updates;
  final List<String> affectedEntityIds;
  final double beforeGapMillimeters;
  final double afterGapMillimeters;
  final double? beforeG1ResidualRadians;
  final double? afterG1ResidualRadians;
  final double maxDisplacementMillimeters;
  final List<String> diagnostics;

  bool get changesGeometry => updates.isNotEmpty;
  bool get isViable => status != SketchContinuityRepairStatus.impossible;
}

/// Pure G1 planning result.  It never calls a solver, writes a Sketch, or
/// records a command.  The connection and tangency tolerances are copied into
/// the result so a future preview can explain exactly what was measured.
class SketchG1RepairPlan {
  SketchG1RepairPlan({
    required this.firstEntityId,
    required this.secondEntityId,
    required this.status,
    required this.currentGapMillimeters,
    required this.currentG1ResidualRadians,
    required this.connectionToleranceMillimeters,
    required this.repairGapToleranceMillimeters,
    required this.tangencyToleranceRadians,
    required alternatives,
    required protectedEntityIds,
    required diagnostics,
  }) : alternatives = List.unmodifiable(alternatives),
       protectedEntityIds = List.unmodifiable(protectedEntityIds),
       diagnostics = List.unmodifiable(diagnostics);

  final String firstEntityId;
  final String secondEntityId;
  final SketchContinuityRepairStatus status;
  final double currentGapMillimeters;
  final double? currentG1ResidualRadians;
  final double connectionToleranceMillimeters;
  final double repairGapToleranceMillimeters;
  final double tangencyToleranceRadians;
  final List<SketchG1RepairAlternative> alternatives;
  final List<String> protectedEntityIds;
  final List<String> diagnostics;

  bool get canRepair => alternatives.any((item) => item.isViable);
}

/// Side-effect-free planner for the first safe G1 repair step.
///
/// Supported geometry is deliberately conservative:
/// * Line–Arc: the circle centre is moved onto the normal of a selected line
///   contact, preserving radius and arc sweep; one alternative preserves each
///   original contact.
/// * Arc–Arc: one centre is moved onto the oriented normal of the other arc at
///   the selected contact, preserving both radii and sweeps.
/// * Spline joins are diagnosed and blocked because changing control points
///   safely requires a deformation/error budget that does not exist here.
///
/// All candidates are checked against the complete entity set.  A candidate
/// that breaks an existing C0/G1 neighbour, a protected endpoint, or an
/// explicit constraint is rejected rather than silently deforming the profile.
class SketchG1ContinuityRepairPlanner {
  const SketchG1ContinuityRepairPlanner({
    this.health = const SketchHealthAnalyzer(),
    this.diagnostic = const SketchContinuityDiagnostic(),
    this.tolerance = const SketchCircularFitTolerance(),
  });

  final SketchHealthAnalyzer health;
  final SketchContinuityDiagnostic diagnostic;
  final SketchCircularFitTolerance tolerance;

  SketchG1RepairPlan plan(
    SketchContinuityJoinDiagnostic selected, {
    required Map<String, SketchEntity> entities,
    Iterable<SketchConstraint> constraints = const <SketchConstraint>[],
  }) {
    final ordered = entities.values.toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    final constraintsList = constraints.toList(growable: false);
    final byId = <String, SketchEntity>{
      for (final entity in ordered) entity.id: entity,
    };
    final first = byId[selected.first.entityId];
    final second = byId[selected.second.entityId];
    final initial = <String>[];
    if (first == null || second == null) {
      return _impossible(
        selected,
        initial..add('A junção G1 referencia entidades ausentes.'),
      );
    }
    if (first.id == second.id) {
      return _impossible(
        selected,
        initial
          ..add('Uma junção G1 não pode usar a mesma entidade duas vezes.'),
      );
    }

    final analysis = diagnostic.analyze(
      ordered,
      constraints: constraintsList,
      tolerance: tolerance,
    );
    final invalidSelected = <String>{
      if (analysis.invalidEntityIds.contains(first.id)) first.id,
      if (analysis.invalidEntityIds.contains(second.id)) second.id,
    };
    if (invalidSelected.isNotEmpty) {
      return _impossible(selected, [
        'A junção G1 contém geometria degenerada ou inválida: '
            '${invalidSelected.toList()..sort()}.',
      ]);
    }
    final current = _findCurrentJoin(analysis.joins, selected);
    if (current == null) {
      return _impossible(
        selected,
        initial..add('A junção G1 está obsoleta ou mudou de endpoint.'),
      );
    }
    final splineDiagnostic = first is SketchSpline || second is SketchSpline
        ? 'Spline não é deformada automaticamente: falta um orçamento seguro '
              'para os pontos de controle.'
        : null;
    if (current.gapMillimeters > health.gapTolerance) {
      return _impossible(
        current,
        initial
          ..addAll([?splineDiagnostic])
          ..add(
            'Gap de ${current.gapMillimeters.toStringAsFixed(6)} mm excede '
            'a tolerância de reparo existente '
            '(${health.gapTolerance.toStringAsFixed(6)} mm).',
          ),
      );
    }

    final protected = <String>{};
    final guards = <String, _G1Guard>{};
    for (final endpoint in [current.first, current.second]) {
      final entity = byId[endpoint.entityId]!;
      final guard = _guard(entity, endpoint.name, constraintsList);
      guards['${endpoint.entityId}:${endpoint.name}'] = guard;
      if (guard.protected) protected.add(entity.id);
    }
    final baseDiagnostics = <String>[];
    if (current.issue == SketchContinuityIssue.overlap ||
        current.issue == SketchContinuityIssue.crossing ||
        current.issue == SketchContinuityIssue.branching) {
      baseDiagnostics.add(
        'A junção possui o problema geométrico ${current.issue.name}; '
        'a correção G1 seria ambígua.',
      );
    }
    if (current.declaredTangent && !current.measuredG1) {
      baseDiagnostics.add(
        'A constraint tangent declarada não coincide com a tangência medida.',
      );
    }
    if (current.declaredCoincident && !current.measuredC0) {
      baseDiagnostics.add(
        'A constraint coincident declarada não coincide com o endpoint medido.',
      );
    }
    for (final entry in guards.entries.where(
      (entry) => entry.value.protected,
    )) {
      baseDiagnostics.add(
        '${entry.key} protegido por ${entry.value.reasons.join(', ')}.',
      );
    }

    if (current.measuredG1 && baseDiagnostics.isEmpty) {
      return SketchG1RepairPlan(
        firstEntityId: current.first.entityId,
        secondEntityId: current.second.entityId,
        status: SketchContinuityRepairStatus.valid,
        currentGapMillimeters: current.gapMillimeters,
        currentG1ResidualRadians: _g1Residual(current),
        connectionToleranceMillimeters:
            tolerance.endpointCoincidenceMillimeters,
        repairGapToleranceMillimeters: health.gapTolerance,
        tangencyToleranceRadians: tolerance.tangencyAngleRadians,
        alternatives: const [],
        protectedEntityIds: const [],
        diagnostics: const ['A junção já possui continuidade C0/G1 medida.'],
      );
    }
    if (baseDiagnostics.any(
      (message) =>
          message.contains('problema geométrico') ||
          message.contains('constraint tangent') ||
          message.contains('constraint coincident'),
    )) {
      return _impossible(current, baseDiagnostics);
    }
    if (first is SketchSpline || second is SketchSpline) {
      return _impossible(current, [
        ...baseDiagnostics,
        ?splineDiagnostic,
      ]);
    }
    if (first is! SketchLine && first is! SketchArc ||
        second is! SketchLine && second is! SketchArc) {
      return _impossible(current, [
        ...baseDiagnostics,
        'Tipo de curva fora do escopo do planejador G1.',
      ]);
    }

    final alternatives = <SketchG1RepairAlternative>[];
    if (first is SketchLine && second is SketchArc) {
      _lineArcAlternatives(
        alternatives,
        line: first,
        lineEndpoint: _endpointName(current, first.id),
        arc: second,
        arcEndpoint: _endpointName(current, second.id),
        entities: byId,
        constraints: constraintsList,
        before: current,
        guards: guards,
      );
    } else if (first is SketchArc && second is SketchLine) {
      _lineArcAlternatives(
        alternatives,
        line: second,
        lineEndpoint: _endpointName(current, second.id),
        arc: first,
        arcEndpoint: _endpointName(current, first.id),
        entities: byId,
        constraints: constraintsList,
        before: current,
        guards: guards,
      );
    } else if (first is SketchArc && second is SketchArc) {
      _arcArcAlternatives(
        alternatives,
        first: first,
        firstEndpoint: _endpointName(current, first.id),
        second: second,
        secondEndpoint: _endpointName(current, second.id),
        entities: byId,
        constraints: constraintsList,
        before: current,
        guards: guards,
      );
    }

    final diagnostics = <String>[...baseDiagnostics];
    if (alternatives.isEmpty) {
      diagnostics.add(
        'Nenhuma solução G1 circular preserva os vínculos e as conexões externas.',
      );
    }
    final hasViable = alternatives.any((item) => item.isViable);
    final hasConditional = alternatives.any(
      (item) =>
          item.status == SketchContinuityRepairStatus.requiresConfirmation,
    );
    if (!hasViable && alternatives.isNotEmpty) {
      diagnostics.addAll(
        alternatives.expand((item) => item.diagnostics).toSet().toList()
          ..sort(),
      );
    }
    return SketchG1RepairPlan(
      firstEntityId: current.first.entityId,
      secondEntityId: current.second.entityId,
      status: hasViable || hasConditional
          ? SketchContinuityRepairStatus.requiresConfirmation
          : SketchContinuityRepairStatus.impossible,
      currentGapMillimeters: current.gapMillimeters,
      currentG1ResidualRadians: _g1Residual(current),
      connectionToleranceMillimeters: tolerance.endpointCoincidenceMillimeters,
      repairGapToleranceMillimeters: health.gapTolerance,
      tangencyToleranceRadians: tolerance.tangencyAngleRadians,
      alternatives: alternatives,
      protectedEntityIds: protected.toList()..sort(),
      diagnostics: diagnostics,
    );
  }

  SketchG1RepairPlan _impossible(
    SketchContinuityJoinDiagnostic join,
    List<String> diagnostics,
  ) => SketchG1RepairPlan(
    firstEntityId: join.first.entityId,
    secondEntityId: join.second.entityId,
    status: SketchContinuityRepairStatus.impossible,
    currentGapMillimeters: join.gapMillimeters,
    currentG1ResidualRadians: _g1Residual(join),
    connectionToleranceMillimeters: tolerance.endpointCoincidenceMillimeters,
    repairGapToleranceMillimeters: health.gapTolerance,
    tangencyToleranceRadians: tolerance.tangencyAngleRadians,
    alternatives: const [],
    protectedEntityIds: const [],
    diagnostics: diagnostics,
  );

  void _lineArcAlternatives(
    List<SketchG1RepairAlternative> output, {
    required SketchLine line,
    required String lineEndpoint,
    required SketchArc arc,
    required String arcEndpoint,
    required Map<String, SketchEntity> entities,
    required List<SketchConstraint> constraints,
    required SketchContinuityJoinDiagnostic before,
    required Map<String, _G1Guard> guards,
  }) {
    final lineGuard = guards['${line.id}:$lineEndpoint'];
    final arcGuard = guards['${arc.id}:$arcEndpoint'];
    final linePoint = _endpoint(line, lineEndpoint);
    final arcPoint = _endpoint(arc, arcEndpoint);

    // Preserve the line's real support and contact.  Only the arc centre and
    // its angular parameter move; radius and signed sweep are unchanged.
    if (arcGuard?.protected != true) {
      final tangent = _lineTangent(line, lineEndpoint);
      final arcProposal = _arcAtTangent(
        arc,
        arcEndpoint,
        linePoint,
        _requiredSecondTangent(
          tangent,
          lineAtStart: lineEndpoint == 'start',
          arcAtStart: arcEndpoint == 'start',
        ),
      );
      if (arcProposal != null) {
        _addCandidate(
          output,
          kind: SketchG1RepairAlternativeKind.lineArcPreserveLineContact,
          before: before,
          entities: entities,
          constraints: constraints,
          proposed: {arc.id: arcProposal},
          updates: [_update(arc, arcProposal, 'moveArcCentreAtLineContact')],
          diagnostics: [
            'Contato da linha preservado em ${line.id}:$lineEndpoint.',
            'Centro/endpoint do arco ajustado à normal tangente da linha.',
          ],
        );
      }
    }

    // Preserve the arc's contact.  The line endpoint is moved to the arc and
    // the arc centre is then solved against the resulting line tangent.
    if (lineGuard?.protected != true && arcGuard?.protected != true) {
      final movedLine = _lineAtEndpoint(line, lineEndpoint, arcPoint);
      if (movedLine != null) {
        final tangent = _lineTangent(movedLine, lineEndpoint);
        final movedArc = _arcAtTangent(
          arc,
          arcEndpoint,
          arcPoint,
          _requiredSecondTangent(
            tangent,
            lineAtStart: lineEndpoint == 'start',
            arcAtStart: arcEndpoint == 'start',
          ),
        );
        if (movedArc != null) {
          _addCandidate(
            output,
            kind: SketchG1RepairAlternativeKind.lineArcPreserveArcContact,
            before: before,
            entities: entities,
            constraints: constraints,
            proposed: {line.id: movedLine, arc.id: movedArc},
            updates: [
              _update(line, movedLine, 'moveLineEndpointToArcContact'),
              _update(arc, movedArc, 'moveArcCentreAtArcContact'),
            ],
            diagnostics: [
              'Contato do arco preservado em ${arc.id}:$arcEndpoint.',
              'Endpoint da linha ajustado sem alterar a entidade externa.',
            ],
          );
        }
      }
    }
  }

  void _arcArcAlternatives(
    List<SketchG1RepairAlternative> output, {
    required SketchArc first,
    required String firstEndpoint,
    required SketchArc second,
    required String secondEndpoint,
    required Map<String, SketchEntity> entities,
    required List<SketchConstraint> constraints,
    required SketchContinuityJoinDiagnostic before,
    required Map<String, _G1Guard> guards,
  }) {
    final firstGuard = guards['${first.id}:$firstEndpoint'];
    final secondGuard = guards['${second.id}:$secondEndpoint'];
    final firstPoint = _endpoint(first, firstEndpoint);
    final secondPoint = _endpoint(second, secondEndpoint);

    if (secondGuard?.protected != true) {
      final proposal = _arcAtTangent(
        second,
        secondEndpoint,
        firstPoint,
        _requiredSecondTangent(
          _arcTangent(first, firstEndpoint),
          lineAtStart: firstEndpoint == 'start',
          arcAtStart: secondEndpoint == 'start',
        ),
      );
      if (proposal != null) {
        _addCandidate(
          output,
          kind: SketchG1RepairAlternativeKind.arcArcPreserveFirstContact,
          before: before,
          entities: entities,
          constraints: constraints,
          proposed: {second.id: proposal},
          updates: [_update(second, proposal, 'moveSecondArcCentre')],
          diagnostics: [
            'Contato do primeiro arco preservado em ${first.id}:$firstEndpoint.',
            'Centro do segundo arco ajustado à normal tangente.',
          ],
        );
      }
    }
    if (firstGuard?.protected != true) {
      final proposal = _arcAtTangent(
        first,
        firstEndpoint,
        secondPoint,
        _requiredSecondTangent(
          _arcTangent(second, secondEndpoint),
          lineAtStart: secondEndpoint == 'start',
          arcAtStart: firstEndpoint == 'start',
        ),
      );
      if (proposal != null) {
        _addCandidate(
          output,
          kind: SketchG1RepairAlternativeKind.arcArcPreserveSecondContact,
          before: before,
          entities: entities,
          constraints: constraints,
          proposed: {first.id: proposal},
          updates: [_update(first, proposal, 'moveFirstArcCentre')],
          diagnostics: [
            'Contato do segundo arco preservado em ${second.id}:$secondEndpoint.',
            'Centro do primeiro arco ajustado à normal tangente.',
          ],
        );
      }
    }
  }

  void _addCandidate(
    List<SketchG1RepairAlternative> output, {
    required SketchG1RepairAlternativeKind kind,
    required SketchContinuityJoinDiagnostic before,
    required Map<String, SketchEntity> entities,
    required List<SketchConstraint> constraints,
    required Map<String, SketchEntity> proposed,
    required List<SketchG1GeometryUpdate> updates,
    required List<String> diagnostics,
  }) {
    final virtual = <String, SketchEntity>{...entities, ...proposed};
    final afterAnalysis = diagnostic.analyze(
      virtual.values,
      constraints: constraints,
      tolerance: tolerance,
    );
    final after = _findJoin(afterAnalysis.joins, before);
    if (after == null) return;
    final effects = _externalBreaks(entities, virtual, constraints, before);
    final breaksExternal = effects.isNotEmpty;
    final afterG1 = _g1Residual(after);
    final status =
        after.issue == SketchContinuityIssue.none &&
            after.measuredC0 &&
            after.measuredG1 &&
            !breaksExternal
        ? SketchContinuityRepairStatus.requiresConfirmation
        : SketchContinuityRepairStatus.impossible;
    final allDiagnostics = <String>[...diagnostics];
    if (!after.measuredC0) {
      allDiagnostics.add(
        'A proposta não preserva C0: resíduo ${after.gapMillimeters.toStringAsFixed(9)} mm.',
      );
    }
    if (!after.measuredG1) {
      allDiagnostics.add(
        'A proposta não alcança G1: resíduo angular '
        '${(after.tangentAngleRadians ?? double.infinity).toStringAsFixed(9)} rad.',
      );
    }
    for (final effect in effects) {
      allDiagnostics.add(
        'A proposta rompe ${effect.firstEntityId}:${effect.first.name} ↔ '
        '${effect.secondEntityId}:${effect.second.name}.',
      );
    }
    final affected = updates.map((item) => item.entityId).toSet().toList()
      ..sort();
    final maxDisplacement = updates.fold<double>(
      0,
      (value, item) => math.max(value, item.displacementMillimeters),
    );
    final signature = updates
        .map((item) => '${item.entityId}:${jsonEncode(item.afterJson)}')
        .join('|');
    if (output.any(
      (item) =>
          item.updates
              .map(
                (update) =>
                    '${update.entityId}:${jsonEncode(update.afterJson)}',
              )
              .join('|') ==
          signature,
    )) {
      return;
    }
    output.add(
      SketchG1RepairAlternative(
        kind: kind,
        status: status,
        updates: updates,
        affectedEntityIds: affected,
        beforeGapMillimeters: before.gapMillimeters,
        afterGapMillimeters: after.gapMillimeters,
        beforeG1ResidualRadians: _g1Residual(before),
        afterG1ResidualRadians: afterG1,
        maxDisplacementMillimeters: maxDisplacement,
        diagnostics: allDiagnostics,
      ),
    );
  }

  List<SketchContinuityJoinDiagnostic> _externalBreaks(
    Map<String, SketchEntity> beforeEntities,
    Map<String, SketchEntity> afterEntities,
    List<SketchConstraint> constraints,
    SketchContinuityJoinDiagnostic selected,
  ) {
    final before = diagnostic
        .analyze(
          beforeEntities.values,
          constraints: constraints,
          tolerance: tolerance,
        )
        .joins;
    final after = diagnostic
        .analyze(
          afterEntities.values,
          constraints: constraints,
          tolerance: tolerance,
        )
        .joins;
    final broken = <SketchContinuityJoinDiagnostic>[];
    for (final join in before) {
      if (_sameJoin(join, selected)) continue;
      if (!join.measuredC0) continue;
      final replacement = _findJoin(after, join);
      if (replacement == null ||
          !replacement.measuredC0 ||
          (join.measuredG1 && !replacement.measuredG1)) {
        broken.add(join);
      }
    }
    return broken;
  }

  SketchG1GeometryUpdate _update(
    SketchEntity original,
    SketchEntity proposed,
    String operation,
  ) {
    final displacement = _entityDisplacement(original, proposed);
    final afterJson = _mutableMap(original.toJson())
      ..['parameters'] = _mutableMap(proposed.parameters);
    return SketchG1GeometryUpdate(
      entityId: original.id,
      entityType: original.type,
      before: original.toJson(),
      after: afterJson,
      displacementMillimeters: displacement,
      operation: operation,
    );
  }

  double _entityDisplacement(SketchEntity first, SketchEntity second) {
    if (first is SketchLine && second is SketchLine) {
      return math.max(
        _distance(_endpoint(first, 'start'), _endpoint(second, 'start')),
        _distance(_endpoint(first, 'end'), _endpoint(second, 'end')),
      );
    }
    if (first is SketchArc && second is SketchArc) {
      return _arcMaximumDisplacement(first, second);
    }
    return double.infinity;
  }

  /// Returns the maximum displacement of corresponding points on two arcs.
  ///
  /// G1 proposals preserve radius and signed sweep.  In that common case the
  /// displacement is the sum of a fixed centre delta and a rotating vector,
  /// so the interior maximum has one analytic stationary direction in
  /// addition to the endpoints.  A deterministic dense fallback is retained
  /// for malformed/non-preserving snapshots so the diagnostic never
  /// under-reports a visible movement.
  double _arcMaximumDisplacement(SketchArc first, SketchArc second) {
    final firstCenter = _arcCenter(first);
    final secondCenter = _arcCenter(second);
    final firstRadius = (first.parameters['radius'] as num?)?.toDouble();
    final secondRadius = (second.parameters['radius'] as num?)?.toDouble();
    final firstStart = (first.parameters['startAngle'] as num?)?.toDouble();
    final firstEnd = (first.parameters['endAngle'] as num?)?.toDouble();
    final secondStart = (second.parameters['startAngle'] as num?)?.toDouble();
    final secondEnd = (second.parameters['endAngle'] as num?)?.toDouble();
    final firstSweep = firstEnd == null || firstStart == null
        ? double.nan
        : firstEnd - firstStart;
    final secondSweep = secondEnd == null || secondStart == null
        ? double.nan
        : secondEnd - secondStart;
    final valid =
        firstRadius != null &&
        secondRadius != null &&
        firstStart != null &&
        secondStart != null &&
        firstRadius.isFinite &&
        secondRadius.isFinite &&
        firstStart.isFinite &&
        secondStart.isFinite &&
        firstSweep.isFinite &&
        secondSweep.isFinite &&
        (firstRadius - secondRadius).abs() <= 1e-9 &&
        (firstSweep - secondSweep).abs() <= 1e-9 &&
        firstSweep.abs() > 1e-9;
    final parameters = <double>[0, 1];
    if (valid) {
      final delta = secondStart - firstStart;
      final sine = math.sin(delta / 2);
      final centreDelta = secondCenter - firstCenter;
      // q(theta) = 2*r*sin(delta/2)*perp(unit(theta + delta/2)).
      // Choose the direction that maximizes centreDelta dot q.
      final targetPhi =
          math.atan2(-centreDelta.x, centreDelta.y) + (sine < 0 ? math.pi : 0);
      final targetTheta = targetPhi - delta / 2;
      final turns = ((firstStart - targetTheta) / (2 * math.pi)).round();
      for (var turn = turns - 2; turn <= turns + 2; turn++) {
        final theta = targetTheta + turn * 2 * math.pi;
        final parameter = (theta - firstStart) / firstSweep;
        if (parameter >= 0 && parameter <= 1) parameters.add(parameter);
      }
    } else {
      return _sampledArcDisplacement(first, second);
    }
    var maximum = 0.0;
    for (final parameter in parameters) {
      final firstPoint = _arcPointAt(first, parameter);
      final secondPoint = _arcPointAt(second, parameter);
      maximum = math.max(maximum, _distance(firstPoint, secondPoint));
    }
    return maximum;
  }

  double _sampledArcDisplacement(SketchArc first, SketchArc second) {
    var maximum = 0.0;
    for (var index = 0; index <= 512; index++) {
      final parameter = index / 512;
      maximum = math.max(
        maximum,
        _distance(
          _arcPointAt(first, parameter),
          _arcPointAt(second, parameter),
        ),
      );
    }
    return maximum;
  }

  SketchVector _arcPointAt(SketchArc arc, double parameter) {
    final center = _arcCenter(arc);
    final radius = (arc.parameters['radius'] as num).toDouble();
    final start = (arc.parameters['startAngle'] as num).toDouble();
    final end = (arc.parameters['endAngle'] as num).toDouble();
    final angle = start + (end - start) * parameter;
    return SketchVector(
      center.x + radius * math.cos(angle),
      center.y + radius * math.sin(angle),
      center.z,
    );
  }

  SketchLine? _lineAtEndpoint(
    SketchLine line,
    String endpoint,
    SketchVector target,
  ) {
    final other = _endpoint(line, endpoint == 'start' ? 'end' : 'start');
    if (_distance(other, target) <= 1e-12) return null;
    return endpoint == 'start'
        ? SketchLine(target, other, id: line.id)
        : SketchLine(other, target, id: line.id);
  }

  SketchArc? _arcAtTangent(
    SketchArc arc,
    String endpoint,
    SketchVector contact,
    SketchVector tangent,
  ) {
    final center = _arcCenter(arc);
    final radius = (arc.parameters['radius'] as num?)?.toDouble();
    final start = (arc.parameters['startAngle'] as num?)?.toDouble();
    final end = (arc.parameters['endAngle'] as num?)?.toDouble();
    if (radius == null ||
        start == null ||
        end == null ||
        !radius.isFinite ||
        radius <= 0 ||
        !start.isFinite ||
        !end.isFinite ||
        !_finite(contact) ||
        contact.z.isNaN ||
        (contact.z - center.z).abs() > 1e-7) {
      return null;
    }
    final sweep = end - start;
    if (!sweep.isFinite ||
        sweep.abs() <= 1e-9 ||
        sweep.abs() > 2 * math.pi + 1e-7) {
      return null;
    }
    final unitTangent = _unit(tangent);
    if (unitTangent == null) return null;
    final sign = sweep < 0 ? -1.0 : 1.0;
    final radial = SketchVector(sign * unitTangent.y, -sign * unitTangent.x, 0);
    final proposedCenter = contact - radial.scale(radius);
    final angle = math.atan2(
      contact.y - proposedCenter.y,
      contact.x - proposedCenter.x,
    );
    final proposedStart = endpoint == 'start' ? angle : angle - sweep;
    final proposedEnd = endpoint == 'end' ? angle : angle + sweep;
    final proposedSweep = proposedEnd - proposedStart;
    if (!proposedSweep.isFinite ||
        proposedSweep.sign != sweep.sign ||
        proposedSweep.abs() <= 1e-9 ||
        proposedSweep.abs() > 2 * math.pi + 1e-7) {
      return null;
    }
    return SketchArc(
      proposedCenter,
      radius,
      proposedStart,
      proposedEnd,
      id: arc.id,
    );
  }

  SketchContinuityJoinDiagnostic? _findJoin(
    Iterable<SketchContinuityJoinDiagnostic> joins,
    SketchContinuityJoinDiagnostic wanted,
  ) {
    for (final join in joins) {
      if (_sameJoin(join, wanted)) return join;
    }
    return null;
  }

  String _endpointName(SketchContinuityJoinDiagnostic join, String entityId) {
    if (join.first.entityId == entityId) return join.first.name;
    if (join.second.entityId == entityId) return join.second.name;
    throw StateError('Join does not contain entity $entityId');
  }

  SketchContinuityJoinDiagnostic? _findCurrentJoin(
    Iterable<SketchContinuityJoinDiagnostic> joins,
    SketchContinuityJoinDiagnostic wanted,
  ) {
    for (final join in joins) {
      final direct =
          join.first.entityId == wanted.first.entityId &&
          join.first.name == wanted.first.name &&
          join.second.entityId == wanted.second.entityId &&
          join.second.name == wanted.second.name &&
          _distance(join.first.point, wanted.first.point) <=
              health.connectionTolerance &&
          _distance(join.second.point, wanted.second.point) <=
              health.connectionTolerance;
      final reverse =
          join.first.entityId == wanted.second.entityId &&
          join.first.name == wanted.second.name &&
          join.second.entityId == wanted.first.entityId &&
          join.second.name == wanted.first.name &&
          _distance(join.first.point, wanted.second.point) <=
              health.connectionTolerance &&
          _distance(join.second.point, wanted.first.point) <=
              health.connectionTolerance;
      if (direct || reverse) return join;
    }
    return null;
  }

  bool _sameJoin(
    SketchContinuityJoinDiagnostic first,
    SketchContinuityJoinDiagnostic second,
  ) {
    final direct =
        first.first.entityId == second.first.entityId &&
        first.first.name == second.first.name &&
        first.second.entityId == second.second.entityId &&
        first.second.name == second.second.name;
    final reverse =
        first.first.entityId == second.second.entityId &&
        first.first.name == second.second.name &&
        first.second.entityId == second.first.entityId &&
        first.second.name == second.first.name;
    return direct || reverse;
  }

  _G1Guard _guard(
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
    for (final constraint in constraints.where((item) => item.enabled)) {
      if (!_references(constraint, entity.id, endpoint)) continue;
      reasons.add('${constraint.type.name} ${constraint.id}');
    }
    return _G1Guard(
      protected: reasons.isNotEmpty,
      reasons: reasons.toSet().toList()..sort(),
    );
  }

  bool _references(SketchConstraint constraint, String id, String endpoint) =>
      constraint.references.any(
        (reference) =>
            reference == id ||
            reference == '$id:$endpoint' ||
            reference.startsWith('$id:'),
      );

  SketchVector _endpoint(SketchEntity entity, String endpoint) {
    if (entity is SketchLine) {
      return SketchVector.fromJson(entity.parameters[endpoint]);
    }
    if (entity is SketchArc) {
      final center = _arcCenter(entity);
      final radius = (entity.parameters['radius'] as num).toDouble();
      final angle = (entity.parameters['${endpoint}Angle'] as num).toDouble();
      return SketchVector(
        center.x + radius * math.cos(angle),
        center.y + radius * math.sin(angle),
        center.z,
      );
    }
    throw StateError('Unsupported G1 endpoint: ${entity.type.name}');
  }

  SketchVector _arcCenter(SketchArc arc) =>
      SketchVector.fromJson(arc.parameters['center']);

  SketchVector _lineTangent(SketchLine line, String endpoint) {
    final start = _endpoint(line, 'start');
    final end = _endpoint(line, 'end');
    final tangent = _unit(end - start);
    if (tangent == null) {
      throw StateError('Degenerate line cannot be G1 planned');
    }
    return tangent;
  }

  SketchVector _arcTangent(SketchArc arc, String endpoint) {
    final center = _arcCenter(arc);
    final point = _endpoint(arc, endpoint);
    final radial = _unit(point - center);
    if (radial == null) throw StateError('Degenerate arc cannot be G1 planned');
    final start = (arc.parameters['startAngle'] as num).toDouble();
    final end = (arc.parameters['endAngle'] as num).toDouble();
    final sign = end - start < 0 ? -1.0 : 1.0;
    return _unit(SketchVector(-radial.y * sign, radial.x * sign))!;
  }

  SketchVector _requiredSecondTangent(
    SketchVector firstTangent, {
    required bool lineAtStart,
    required bool arcAtStart,
  }) => firstTangent.scale(lineAtStart == arcAtStart ? -1 : 1);

  SketchVector? _unit(SketchVector value) {
    final length = math.sqrt(value.x * value.x + value.y * value.y);
    if (!length.isFinite || length <= 1e-12) return null;
    return SketchVector(value.x / length, value.y / length, 0);
  }

  bool _finite(SketchVector value) =>
      value.x.isFinite && value.y.isFinite && value.z.isFinite;

  double _distance(SketchVector first, SketchVector second) {
    final delta = first - second;
    return math.sqrt(delta.dot(delta));
  }

  double? _g1Residual(SketchContinuityJoinDiagnostic join) =>
      join.orientedTangentAngleRadians ?? join.tangentAngleRadians;
}

class _G1Guard {
  const _G1Guard({required this.protected, required this.reasons});
  final bool protected;
  final List<String> reasons;
}

Map<String, dynamic> _freezeMap(Map<String, dynamic> source) =>
    Map.unmodifiable({
      for (final entry in source.entries) entry.key: _freeze(entry.value),
    });

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map.unmodifiable({
      for (final entry in value.entries)
        entry.key.toString(): _freeze(entry.value),
    });
  }
  if (value is List) return List.unmodifiable(value.map(_freeze));
  return value;
}

Map<String, dynamic> _mutableMap(Map<String, dynamic> source) =>
    jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
