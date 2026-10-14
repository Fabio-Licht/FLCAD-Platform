import 'dart:convert';
import 'dart:io';

import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/validation/geometry_outcome.dart';
import 'package:flcad_mobile/core/cad_kernel/validation/validation_contracts.dart';
import 'package:flcad_mobile/core/geometric_kernel/diagnostics/geometry_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Frente B.1a — contratos do resultado geométrico tipado.
GeometryShapeIdentity _identity({String? digest}) {
  final base = GeometryShapeIdentity.fromHandle(
    ShapeHandle.reference(
      persistentId: 'e1_abc',
      kernelId: 'occ-kernel',
      type: CADShapeType.solid,
      fingerprint: 'occ-1234567',
    ),
  );
  return digest == null ? base : base.withGeometryDigest(digest);
}

GeometryValidityReport _cleanValidity() => GeometryValidityReport(
  checked: true,
  checks: const {GeometryValidationCheck.manifold},
  diagnostics: const [],
  source: GeometryEvidenceSource.brepValidity,
);

GeometryPostConditionReport _satisfied(String id) => GeometryPostConditionReport(
  id: id,
  satisfied: true,
  source: GeometryEvidenceSource.brepPostCondition,
  expected: 'face consumida',
  observed: 'face consumida',
);

GeometryMetricEvidence _brepMetric(String name, double value) =>
    GeometryMetricEvidence.brep(name: name, value: value, unit: 'mm3');

void main() {
  group('contrato do resultado geométrico', () {
    test('sucesso alterado exige validação, pós-condição e métrica BREP', () {
      final outcome = GeometryOutcome.successChanged(
        operation: 'FILLET',
        operationClass: GeometryOperationClass.fillet,
        shape: _identity(digest: 'brep:area=123.4'),
        validity: _cleanValidity(),
        postConditions: [_satisfied('fillet.edge_consumed')],
        metrics: [_brepMetric('volume', 1234.5)],
      );

      expect(outcome.status, GeometryOutcomeStatus.successChanged);
      expect(outcome.isValidatedSuccess, isTrue);
      expect(outcome.isFailure, isFalse);
      expect(outcome.requiresVerification, isFalse);
      expect(outcome.evidence, contains(GeometryEvidenceSource.brepMetric));
    });

    test('sucesso alterado é recusado sem validação efetiva', () {
      expect(
        () => GeometryOutcome.successChanged(
          operation: 'FILLET',
          operationClass: GeometryOperationClass.fillet,
          shape: _identity(),
          validity: GeometryValidityReport.notChecked,
          postConditions: [_satisfied('fillet.edge_consumed')],
          metrics: [_brepMetric('volume', 1)],
        ),
        throwsArgumentError,
      );
    });

    test('sucesso alterado é recusado com métrica apenas de malha/STL', () {
      expect(
        () => GeometryOutcome.successChanged(
          operation: 'HEAL',
          operationClass: GeometryOperationClass.heal,
          shape: _identity(),
          validity: _cleanValidity(),
          postConditions: [_satisfied('heal.errors_removed')],
          metrics: [
            GeometryMetricEvidence.mesh(
              name: 'stl_volume',
              value: 10,
              unit: 'mm3',
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('sucesso alterado é recusado com pós-condição não satisfeita', () {
      expect(
        () => GeometryOutcome.successChanged(
          operation: 'SEW',
          operationClass: GeometryOperationClass.surfaceEdit,
          shape: _identity(),
          validity: _cleanValidity(),
          postConditions: [
            GeometryPostConditionReport(
              id: 'sew.free_edges',
              satisfied: false,
              source: GeometryEvidenceSource.brepPostCondition,
            ),
          ],
          metrics: [_brepMetric('area', 5)],
        ),
        throwsArgumentError,
      );
    });

    test('sucesso inalterado representa reparo idempotente, não falha', () {
      final outcome = GeometryOutcome.successUnchanged(
        operation: 'HEAL',
        operationClass: GeometryOperationClass.heal,
        shape: _identity(),
        idempotence: GeometryIdempotence.repairsMayBeUnchanged,
        postConditions: [_satisfied('heal.no_defects_found')],
      );

      expect(outcome.status, GeometryOutcomeStatus.successUnchanged);
      expect(outcome.isFailure, isFalse);
      expect(outcome.isRepairUnchanged, isTrue);
      expect(outcome.isValidatedSuccess, isTrue);
    });

    test('sucesso inalterado exige semântica de idempotência explícita', () {
      expect(
        () => GeometryOutcome.successUnchanged(
          operation: 'SEW',
          operationClass: GeometryOperationClass.surfaceEdit,
          shape: _identity(),
          idempotence: GeometryIdempotence.changeExpected,
          postConditions: [_satisfied('sew.free_edges')],
        ),
        throwsArgumentError,
      );
    });

    test('falha de execução nativa carrega diagnóstico tipado', () {
      final outcome = GeometryOutcome.failure(
        operation: 'LOFT',
        operationClass: GeometryOperationClass.loft,
        reason: 'BRepOffsetAPI_ThruSections failed',
      );

      expect(outcome.isFailure, isTrue);
      expect(outcome.isValidatedSuccess, isFalse);
      expect(outcome.execution, GeometryExecutionStatus.nativeFailure);
      expect(
        outcome.diagnostics.map((item) => item.code),
        contains('outcome.failure'),
      );
      expect(outcome.errors, isNotEmpty);
      expect(outcome.statePolicy, OriginalStatePolicy.preservedOnFailure);
    });

    test('token inválido e shape nulo são falhas de pré-condição/execução', () {
      final unknownToken = GeometryOutcome.failure(
        operation: 'SURFACE OPERATION',
        operationClass: GeometryOperationClass.surfaceEdit,
        reason: 'Unknown native shape token',
        execution: GeometryExecutionStatus.invalidPrecondition,
      );
      final nullShape = GeometryOutcome.failure(
        operation: 'EXTRUDE',
        operationClass: GeometryOperationClass.extrude,
        reason: 'OCCT produced a null shape',
      );

      expect(unknownToken.execution, GeometryExecutionStatus.invalidPrecondition);
      expect(unknownToken.isFailure, isTrue);
      expect(nullShape.execution, GeometryExecutionStatus.nativeFailure);
      expect(nullShape.shape, isNull);
    });

    test('execução concluída sem verificação não é aprovação', () {
      final outcome = GeometryOutcome.notVerified(
        operation: 'REVOLVE',
        operationClass: GeometryOperationClass.revolve,
        reason: 'executou; validação geométrica não foi executada',
        shape: _identity(),
      );

      expect(outcome.status, GeometryOutcomeStatus.notVerified);
      expect(outcome.execution, GeometryExecutionStatus.completed);
      expect(outcome.isValidatedSuccess, isFalse);
      expect(outcome.requiresVerification, isTrue);
      expect(outcome.validity.checked, isFalse);
      expect(
        outcome.diagnostics.map((item) => item.severity),
        contains(GeometrySeverity.warning),
      );
    });

    test('pós-condição não satisfeita produz falha classificada', () {
      final outcome = GeometryOutcome.failure(
        operation: 'DELETE FACE',
        operationClass: GeometryOperationClass.surfaceEdit,
        reason: 'face alvo permanece presente',
        execution: GeometryExecutionStatus.completed,
        postConditions: [
          GeometryPostConditionReport(
            id: 'delete_face.target_absent',
            satisfied: false,
            source: GeometryEvidenceSource.brepPostCondition,
            expected: 'ausente',
            observed: 'presente',
          ),
        ],
      );

      expect(outcome.isFailure, isTrue);
      expect(outcome.postConditions.single.satisfied, isFalse);
      expect(outcome.requiresVerification, isTrue);
    });

    test('falha sem causa comprovada é recusada', () {
      expect(
        () => GeometryOutcome.failure(
          operation: 'TRIM',
          operationClass: GeometryOperationClass.surfaceEdit,
          reason: 'sem causa',
          execution: GeometryExecutionStatus.completed,
          postConditions: [_satisfied('trim.piece_removed')],
        ),
        throwsArgumentError,
      );
    });

    test('diagnóstico preserva código estável, severidade e composição', () {
      final entry = GeometryOutcomeDiagnostic.fromDiagnostic(
        const GeometryDiagnostic('brep-check.invalid-shell', 'shell inválido'),
        severity: GeometrySeverity.error,
        scope: 'shell#2',
      );

      expect(entry.code, 'brep-check.invalid-shell');
      expect(entry.message, 'shell inválido');
      expect(entry.severity, GeometrySeverity.error);
      expect(entry.isError, isTrue);
      expect(entry.scope, 'shell#2');
      expect(entry.toDiagnostic().code, entry.code);
      expect(
        GeometryValidityReport(
          checked: true,
          checks: const {GeometryValidationCheck.invalidShell},
          diagnostics: [entry],
          source: GeometryEvidenceSource.brepValidity,
        ).hasErrors,
        isTrue,
      );
    });

    test('fingerprint de handle não é identidade geométrica', () {
      final fromHandle = _identity();
      final withDigest = _identity(digest: 'brep:volume=1000.0');

      expect(fromHandle.handleFingerprint, 'occ-1234567');
      expect(fromHandle.geometryDigest, isNull);
      expect(withDigest.geometryDigest, 'brep:volume=1000.0');
      expect(
        fromHandle.toJson().containsKey('geometryDigest'),
        isFalse,
        reason: 'sem medição BREP não existe digest: não invente identidade',
      );
      expect(fromHandle.toJson()['handleFingerprint'], 'occ-1234567');
    });

    test('métricas distinguem explicitamente BREP de malha/STL', () {
      final brep = _brepMetric('volume', 10);
      final mesh = GeometryMetricEvidence.mesh(
        name: 'stl_volume',
        value: 10,
        unit: 'mm3',
      );

      expect(brep.isBrep, isTrue);
      expect(mesh.isBrep, isFalse);
      expect(brep.source, GeometryEvidenceSource.brepMetric);
      expect(mesh.source, GeometryEvidenceSource.meshMetric);
      expect(brep.toJson()['source'], 'brepMetric');
      expect(mesh.toJson()['source'], 'meshMetric');
    });

    test('serialização preserva todos os campos e volta ao mesmo estado', () {
      final outcome = GeometryOutcome.successChanged(
        operation: 'FILLET',
        operationClass: GeometryOperationClass.fillet,
        shape: _identity(digest: 'brep:area=1.0'),
        validity: _cleanValidity(),
        postConditions: [_satisfied('fillet.edge_consumed')],
        metrics: [_brepMetric('volume', 1234.5)],
        diagnostics: [
          GeometryOutcomeDiagnostic.fromDiagnostic(
            const GeometryDiagnostic('fillet.radius_clamped', 'raio ajustado'),
            severity: GeometrySeverity.warning,
          ),
        ],
        attributes: const {'radius': 2.5},
      );

      final encoded = jsonEncode(outcome.toJson());
      final decoded = GeometryOutcome.fromJson(
        (jsonDecode(encoded) as Map).cast<String, Object?>(),
      );

      expect(decoded.status, outcome.status);
      expect(decoded.execution, outcome.execution);
      expect(decoded.idempotence, outcome.idempotence);
      expect(decoded.validity.checked, isTrue);
      expect(decoded.validity.checks, outcome.validity.checks);
      expect(decoded.postConditions.single.id, 'fillet.edge_consumed');
      expect(decoded.metrics.single.value, 1234.5);
      expect(decoded.diagnostics.single.code, 'fillet.radius_clamped');
      expect(decoded.diagnostics.single.severity, GeometrySeverity.warning);
      expect(decoded.evidence, outcome.evidence);
      expect(decoded.shape!.geometryDigest, 'brep:area=1.0');
      expect(decoded.attributes, {'radius': 2.5});
      expect(decoded.isValidatedSuccess, isTrue);
    });

    test('contrato é passivo: sem kernel, runtime, IO ou publicação', () {
      final source = File(
        'lib/core/cad_kernel/validation/geometry_outcome.dart',
      ).readAsStringSync();
      for (final forbidden in const [
        'open_cascade',
        'kernel_transaction',
        'cad_runtime_transactions',
        'desktop_command_coordinator',
        'command_registry',
        'project_manager',
        'dart:io',
        'dart:ffi',
        'ShapeHandle.reference(',
        'shape_count',
        'destroyShape',
      ]) {
        expect(
          source.contains(forbidden),
          isFalse,
          reason: 'o contrato não pode tocar $forbidden',
        );
      }
      expect(source.contains('validate('), isFalse,
          reason: 'B.1a não executa validação automática');
    });

    test('classificações exigem evidência: nenhum atalho implícito', () {
      final notVerified = GeometryOutcome.notVerified(
        operation: 'EXTRUDE',
        operationClass: GeometryOperationClass.extrude,
        reason: 'sem verificação',
      );
      final unchanged = GeometryOutcome.successUnchanged(
        operation: 'MERGE FACES',
        operationClass: GeometryOperationClass.surfaceEdit,
        shape: _identity(),
        idempotence: GeometryIdempotence.tolerantEquals,
        postConditions: [_satisfied('merge.already_merged')],
      );

      expect(notVerified.isValidatedSuccess, isFalse);
      expect(unchanged.isFailure, isFalse);
      expect(unchanged.requiresVerification, isFalse);
      expect(unchanged.idempotence, GeometryIdempotence.tolerantEquals);
    });
  });
}
