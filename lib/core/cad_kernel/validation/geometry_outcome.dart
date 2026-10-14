/// Frente B.1a — contrato tipado de confiabilidade geométrica.
///
/// Este arquivo é **aditivo e passivo**: só descreve resultados. Ele não chama o
/// kernel, não valida automaticamente, não publica shapes/tokens e não conhece
/// documento, seleção, Undo/Redo, Save/Open, Preview/Apply ou CommandRegistry.
/// A integração às operações é trabalho de B.1b/B.1c/B.1d.
///
/// Invariantes centrais (cada uma tem teste dedicado):
/// * sucesso nativo **não** é sucesso geométrico validado — existe um estado
///   próprio para "executou, mas não foi verificado";
/// * reparo legitimamente inalterado tem estado próprio e não é falha;
/// * `fingerprint` de handle nunca é tratado como identidade geométrica;
/// * métrica BREP nunca é derivada de malha/STL;
/// * nenhuma conclusão de sucesso validado é possível sem as evidências
///   exigidas (as fábricas recusam).
library;

import '../../geometric_kernel/diagnostics/geometry_diagnostics.dart';
import '../models/kernel_models.dart';
import 'validation_contracts.dart';

/// Classe de operação, para agrupar pós-condições e evidências por natureza.
enum GeometryOperationClass {
  extrude,
  revolve,
  booleanOp,
  fillet,
  chamfer,
  heal,
  removeFillet,
  sweep,
  loft,
  surfaceCreate,
  surfaceEdit,
  importShape,
  exportShape,
  mesh,
  unknown,
}

/// Como a chamada nativa terminou (execução, não qualidade do resultado).
enum GeometryExecutionStatus {
  completed,
  nativeFailure,
  invalidPrecondition,
  unsupported,
}

/// Classificação final do resultado geométrico.
enum GeometryOutcomeStatus {
  /// Executou, mudou a geometria e as evidências comprovam a mudança.
  successChanged,

  /// Executou e o resultado é legitimamente igual ao original (idempotência).
  successUnchanged,

  /// Não produziu resultado aceitável (execução, validação ou pós-condição).
  failure,

  /// Executou, mas nenhuma evidência geométrica foi coletada: **não** é
  /// aprovação.
  notVerified,
}

enum GeometrySeverity { info, warning, error }

/// De onde veio uma evidência. Métricas BREP e métricas de malha/STL são
/// mundos distintos neste contrato.
enum GeometryEvidenceSource {
  nativeExecution,
  brepValidity,
  brepPostCondition,
  brepMetric,
  meshMetric,
}

/// Semântica de igualdade admitida para a operação.
enum GeometryIdempotence {
  /// A operação deve mudar a geometria; igualdade é suspeita.
  changeExpected,

  /// Igualdade dentro de tolerância explícita é resultado legítimo.
  tolerantEquals,

  /// Reconstruções podem terminar sem alteração (ex.: reparo sem defeitos).
  repairsMayBeUnchanged,

  /// Igualdade exata é o resultado esperado.
  exactEquals,
}

/// O que aconteceu com o estado original quando o resultado é falha.
enum OriginalStatePolicy {
  preservedOnFailure,
  originalMutatedWithinTransaction,
  unknown,
}

/// Diagnóstico com código estável, severidade e escopo.
///
/// Compõe [GeometryDiagnostic] em vez de recriar código/mensagem, para não
/// manter um segundo sistema incompatível.
class GeometryOutcomeDiagnostic {
  const GeometryOutcomeDiagnostic({
    required this.diagnostic,
    required this.severity,
    required this.source,
    this.scope,
  });

  GeometryOutcomeDiagnostic.fromDiagnostic(
    GeometryDiagnostic diagnostic, {
    required GeometrySeverity severity,
    GeometryEvidenceSource source = GeometryEvidenceSource.brepValidity,
    String? scope,
  }) : this(
         diagnostic: diagnostic,
         severity: severity,
         source: source,
         scope: scope,
       );

  final GeometryDiagnostic diagnostic;
  final GeometrySeverity severity;
  final GeometryEvidenceSource source;

  /// Sub-shape ou token de origem (ex.: `face#12`). Nunca identidade geométrica.
  final String? scope;

  String get code => diagnostic.code;
  String get message => diagnostic.message;
  bool get isError => severity == GeometrySeverity.error;

  GeometryDiagnostic toDiagnostic() => diagnostic;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'severity': severity.name,
    'source': source.name,
    if (scope != null) 'scope': scope,
  };

  factory GeometryOutcomeDiagnostic.fromJson(Map<String, Object?> json) =>
      GeometryOutcomeDiagnostic(
        diagnostic: GeometryDiagnostic(
          json['code']! as String,
          json['message']! as String,
        ),
        severity: GeometrySeverity.values.byName(json['severity']! as String),
        source: GeometryEvidenceSource.values.byName(json['source']! as String),
        scope: json['scope'] as String?,
      );

  @override
  String toString() => '${severity.name}:$code'
      '${scope == null ? '' : '($scope)'} $message';
}

/// Identidade do shape no contrato.
///
/// [handleFingerprint] é o hash de handle do kernel: identifica **alocação**, não
/// geometria. [geometryDigest] só pode ser preenchido por evidência BREP
/// verificada; ficar nulo é a resposta honesta quando não houve medição.
class GeometryShapeIdentity {
  const GeometryShapeIdentity({
    required this.persistentId,
    required this.kernelId,
    required this.shapeType,
    required this.revision,
    this.handleFingerprint,
    this.geometryDigest,
  });

  factory GeometryShapeIdentity.fromHandle(ShapeHandle handle) =>
      GeometryShapeIdentity(
        persistentId: handle.persistentId,
        kernelId: handle.kernelId,
        shapeType: handle.type,
        revision: handle.revision,
        handleFingerprint: handle.fingerprint,
      );

  final String persistentId;
  final String kernelId;
  final CADShapeType shapeType;
  final int revision;

  /// Hash de handle — **não** é identidade geométrica.
  final String? handleFingerprint;

  /// Digest geométrico comprovado por medição BREP (nulo quando não medido).
  final String? geometryDigest;

  GeometryShapeIdentity withGeometryDigest(String digest) =>
      GeometryShapeIdentity(
        persistentId: persistentId,
        kernelId: kernelId,
        shapeType: shapeType,
        revision: revision,
        handleFingerprint: handleFingerprint,
        geometryDigest: digest,
      );

  Map<String, Object?> toJson() => {
    'persistentId': persistentId,
    'kernelId': kernelId,
    'shapeType': shapeType.name,
    'revision': revision,
    if (handleFingerprint != null) 'handleFingerprint': handleFingerprint,
    if (geometryDigest != null) 'geometryDigest': geometryDigest,
  };

  factory GeometryShapeIdentity.fromJson(Map<String, Object?> json) =>
      GeometryShapeIdentity(
        persistentId: json['persistentId']! as String,
        kernelId: json['kernelId']! as String,
        shapeType: CADShapeType.values.byName(json['shapeType']! as String),
        revision: json['revision']! as int,
        handleFingerprint: json['handleFingerprint'] as String?,
        geometryDigest: json['geometryDigest'] as String?,
      );

  @override
  String toString() => '$persistentId@r$revision (${shapeType.name})';
}

/// Resultado da validação topológica/geométrica (BRep).
class GeometryValidityReport {
  const GeometryValidityReport({
    required this.checked,
    required this.checks,
    required this.diagnostics,
    required this.source,
  });

  /// O estado honesto de quem não verificou.
  static const GeometryValidityReport notChecked = GeometryValidityReport(
    checked: false,
    checks: {},
    diagnostics: [],
    source: GeometryEvidenceSource.nativeExecution,
  );

  final bool checked;
  final Set<GeometryValidationCheck> checks;
  final List<GeometryOutcomeDiagnostic> diagnostics;
  final GeometryEvidenceSource source;

  bool get hasErrors => diagnostics.any((item) => item.isError);
  bool get hasWarnings =>
      diagnostics.any((item) => item.severity == GeometrySeverity.warning);
  bool get isClean => checked && !hasErrors;

  Map<String, Object?> toJson() => {
    'checked': checked,
    'checks': checks.map((check) => check.name).toList(),
    'source': source.name,
    'diagnostics': diagnostics.map((item) => item.toJson()).toList(),
  };

  factory GeometryValidityReport.fromJson(Map<String, Object?> json) =>
      GeometryValidityReport(
        checked: json['checked']! as bool,
        checks: {
          for (final name in (json['checks']! as List).cast<String>())
            GeometryValidationCheck.values.byName(name),
        },
        diagnostics: [
          for (final item in (json['diagnostics']! as List))
            GeometryOutcomeDiagnostic.fromJson(
              (item as Map).cast<String, Object?>(),
            ),
        ],
        source: GeometryEvidenceSource.values.byName(json['source']! as String),
      );
}

/// Pós-condição específica da operação, com valor esperado e observado.
class GeometryPostConditionReport {
  const GeometryPostConditionReport({
    required this.id,
    required this.satisfied,
    required this.source,
    this.expected,
    this.observed,
    this.diagnostics = const [],
  });

  /// Código estável da pós-condição (ex.: `heal.errors_removed`).
  final String id;
  final bool satisfied;
  final GeometryEvidenceSource source;
  final Object? expected;
  final Object? observed;
  final List<GeometryOutcomeDiagnostic> diagnostics;

  Map<String, Object?> toJson() => {
    'id': id,
    'satisfied': satisfied,
    'source': source.name,
    if (expected != null) 'expected': expected,
    if (observed != null) 'observed': observed,
    'diagnostics': diagnostics.map((item) => item.toJson()).toList(),
  };

  factory GeometryPostConditionReport.fromJson(Map<String, Object?> json) =>
      GeometryPostConditionReport(
        id: json['id']! as String,
        satisfied: json['satisfied']! as bool,
        source: GeometryEvidenceSource.values.byName(json['source']! as String),
        expected: json['expected'],
        observed: json['observed'],
        diagnostics: [
          for (final item in (json['diagnostics']! as List))
            GeometryOutcomeDiagnostic.fromJson(
              (item as Map).cast<String, Object?>(),
            ),
        ],
      );

  @override
  String toString() =>
      '$id=${satisfied ? 'ok' : 'FAIL'}'
      '${expected == null ? '' : ' (esperado $expected)}'}'
      '${observed == null ? '' : ' (observado $observed)'}';
}

/// Métrica medida, com a fonte explícita.
class GeometryMetricEvidence {
  const GeometryMetricEvidence._({
    required this.name,
    required this.value,
    required this.unit,
    required this.source,
  });

  /// Métrica medida no BRep (nunca derivada de malha/STL).
  factory GeometryMetricEvidence.brep({
    required String name,
    required double value,
    required String unit,
  }) => GeometryMetricEvidence._(
    name: name,
    value: value,
    unit: unit,
    source: GeometryEvidenceSource.brepMetric,
  );

  /// Métrica medida na tesselação/STL — evidência de outra natureza.
  factory GeometryMetricEvidence.mesh({
    required String name,
    required double value,
    required String unit,
  }) => GeometryMetricEvidence._(
    name: name,
    value: value,
    unit: unit,
    source: GeometryEvidenceSource.meshMetric,
  );

  final String name;
  final double value;
  final String unit;
  final GeometryEvidenceSource source;

  bool get isBrep => source == GeometryEvidenceSource.brepMetric;

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'unit': unit,
    'source': source.name,
  };

  factory GeometryMetricEvidence.fromJson(Map<String, Object?> json) {
    final source = GeometryEvidenceSource.values.byName(
      json['source']! as String,
    );
    final name = json['name']! as String;
    final value = (json['value']! as num).toDouble();
    final unit = json['unit']! as String;
    return switch (source) {
      GeometryEvidenceSource.brepMetric => GeometryMetricEvidence.brep(
        name: name,
        value: value,
        unit: unit,
      ),
      GeometryEvidenceSource.meshMetric => GeometryMetricEvidence.mesh(
        name: name,
        value: value,
        unit: unit,
      ),
      _ => GeometryMetricEvidence._(
        name: name,
        value: value,
        unit: unit,
        source: source,
      ),
    };
  }
}

/// Resultado geométrico tipado.
class GeometryOutcome {
  const GeometryOutcome._({
    required this.operation,
    required this.operationClass,
    required this.status,
    required this.execution,
    required this.validity,
    required this.postConditions,
    required this.metrics,
    required this.idempotence,
    required this.statePolicy,
    required this.diagnostics,
    required this.evidence,
    this.shape,
    this.attributes = const {},
  });

  /// Executou, mudou a geometria e **comprovou** a mudança.
  ///
  /// Exige: execução completa, identidade do resultado, validação efetivamente
  /// feita e limpa, ao menos uma pós-condição satisfeita e ao menos uma métrica
  /// medida **no BRep** (malha/STL não serve como prova de mudança BRep).
  factory GeometryOutcome.successChanged({
    required String operation,
    required GeometryOperationClass operationClass,
    required GeometryShapeIdentity shape,
    required GeometryValidityReport validity,
    required List<GeometryPostConditionReport> postConditions,
    required List<GeometryMetricEvidence> metrics,
    GeometryIdempotence idempotence = GeometryIdempotence.changeExpected,
    OriginalStatePolicy statePolicy =
        OriginalStatePolicy.preservedOnFailure,
    List<GeometryOutcomeDiagnostic> diagnostics = const [],
    Map<String, Object?> attributes = const {},
  }) {
    if (!validity.checked || validity.hasErrors) {
      throw ArgumentError(
        'successChanged exige validação BREP efetiva e sem erros '
        '(use GeometryOutcome.notVerified quando não houve verificação).',
      );
    }
    if (postConditions.isEmpty ||
        postConditions.any((item) => !item.satisfied)) {
      throw ArgumentError(
        'successChanged exige ao menos uma pós-condição, todas satisfeitas.',
      );
    }
    final brepMetrics = metrics.where((item) => item.isBrep).toList();
    if (brepMetrics.isEmpty) {
      throw ArgumentError(
        'successChanged exige métrica medida no BRep; métricas de malha/STL '
        'não comprovam alteração geométrica.',
      );
    }
    return GeometryOutcome._(
      operation: operation,
      operationClass: operationClass,
      status: GeometryOutcomeStatus.successChanged,
      execution: GeometryExecutionStatus.completed,
      validity: validity,
      postConditions: List.unmodifiable(postConditions),
      metrics: List.unmodifiable(metrics),
      idempotence: idempotence,
      statePolicy: statePolicy,
      diagnostics: List.unmodifiable(diagnostics),
      evidence: {
        GeometryEvidenceSource.nativeExecution,
        GeometryEvidenceSource.brepValidity,
        GeometryEvidenceSource.brepPostCondition,
        GeometryEvidenceSource.brepMetric,
      },
      shape: shape,
      attributes: Map.unmodifiable(attributes),
    );
  }

  /// Executou e o resultado é legitimamente igual ao original.
  factory GeometryOutcome.successUnchanged({
    required String operation,
    required GeometryOperationClass operationClass,
    required GeometryShapeIdentity shape,
    required GeometryIdempotence idempotence,
    required List<GeometryPostConditionReport> postConditions,
    GeometryValidityReport validity = GeometryValidityReport.notChecked,
    List<GeometryMetricEvidence> metrics = const [],
    OriginalStatePolicy statePolicy =
        OriginalStatePolicy.preservedOnFailure,
    List<GeometryOutcomeDiagnostic> diagnostics = const [],
    Map<String, Object?> attributes = const {},
  }) {
    if (idempotence == GeometryIdempotence.changeExpected) {
      throw ArgumentError(
        'successUnchanged exige semântica de idempotência explícita '
        '(tolerantEquals, repairsMayBeUnchanged ou exactEquals).',
      );
    }
    if (postConditions.isEmpty ||
        postConditions.any((item) => !item.satisfied)) {
      throw ArgumentError(
        'successUnchanged exige pós-condições satisfeitas que expliquem a '
        'igualdade (nunca presuma igualdade sem evidência).',
      );
    }
    return GeometryOutcome._(
      operation: operation,
      operationClass: operationClass,
      status: GeometryOutcomeStatus.successUnchanged,
      execution: GeometryExecutionStatus.completed,
      validity: validity,
      postConditions: List.unmodifiable(postConditions),
      metrics: List.unmodifiable(metrics),
      idempotence: idempotence,
      statePolicy: statePolicy,
      diagnostics: List.unmodifiable(diagnostics),
      evidence: {
        GeometryEvidenceSource.nativeExecution,
        GeometryEvidenceSource.brepPostCondition,
      },
      shape: shape,
      attributes: Map.unmodifiable(attributes),
    );
  }

  /// Não produziu resultado aceitável.
  factory GeometryOutcome.failure({
    required String operation,
    required GeometryOperationClass operationClass,
    required String reason,
    GeometryExecutionStatus execution = GeometryExecutionStatus.nativeFailure,
    GeometryShapeIdentity? shape,
    GeometryValidityReport validity = GeometryValidityReport.notChecked,
    List<GeometryPostConditionReport> postConditions = const [],
    List<GeometryMetricEvidence> metrics = const [],
    GeometrySeverity severity = GeometrySeverity.error,
    OriginalStatePolicy statePolicy =
        OriginalStatePolicy.preservedOnFailure,
    List<GeometryOutcomeDiagnostic> diagnostics = const [],
    Map<String, Object?> attributes = const {},
  }) {
    if (execution == GeometryExecutionStatus.completed &&
        !diagnostics.any((item) => item.isError) &&
        postConditions.every((item) => item.satisfied)) {
      throw ArgumentError(
        'failure exige uma causa: execução não concluída, erro diagnosticado '
        'ou pós-condição não satisfeita.',
      );
    }
    return GeometryOutcome._(
      operation: operation,
      operationClass: operationClass,
      status: GeometryOutcomeStatus.failure,
      execution: execution,
      validity: validity,
      postConditions: List.unmodifiable(postConditions),
      metrics: List.unmodifiable(metrics),
      idempotence: GeometryIdempotence.changeExpected,
      statePolicy: statePolicy,
      diagnostics: List.unmodifiable([
        ...diagnostics,
        GeometryOutcomeDiagnostic(
          diagnostic: GeometryDiagnostic('outcome.failure', reason),
          severity: severity,
          source: GeometryEvidenceSource.nativeExecution,
        ),
      ]),
      evidence: {GeometryEvidenceSource.nativeExecution},
      shape: shape,
      attributes: Map.unmodifiable(attributes),
    );
  }

  /// Executou, mas sem evidência geométrica coletada: **não** é aprovação.
  factory GeometryOutcome.notVerified({
    required String operation,
    required GeometryOperationClass operationClass,
    required String reason,
    GeometryShapeIdentity? shape,
    GeometryExecutionStatus execution = GeometryExecutionStatus.completed,
    List<GeometryMetricEvidence> metrics = const [],
    List<GeometryOutcomeDiagnostic> diagnostics = const [],
    Map<String, Object?> attributes = const {},
  }) => GeometryOutcome._(
    operation: operation,
    operationClass: operationClass,
    status: GeometryOutcomeStatus.notVerified,
    execution: execution,
    validity: GeometryValidityReport.notChecked,
    postConditions: const [],
    metrics: List.unmodifiable(metrics),
    idempotence: GeometryIdempotence.changeExpected,
    statePolicy: OriginalStatePolicy.unknown,
    diagnostics: List.unmodifiable([
      ...diagnostics,
      GeometryOutcomeDiagnostic(
        diagnostic: GeometryDiagnostic('outcome.not-verified', reason),
        severity: GeometrySeverity.warning,
        source: GeometryEvidenceSource.nativeExecution,
      ),
    ]),
    evidence: {GeometryEvidenceSource.nativeExecution},
    shape: shape,
    attributes: Map.unmodifiable(attributes),
  );

  final String operation;
  final GeometryOperationClass operationClass;
  final GeometryOutcomeStatus status;
  final GeometryExecutionStatus execution;
  final GeometryValidityReport validity;
  final List<GeometryPostConditionReport> postConditions;
  final List<GeometryMetricEvidence> metrics;
  final GeometryIdempotence idempotence;
  final OriginalStatePolicy statePolicy;
  final List<GeometryOutcomeDiagnostic> diagnostics;

  /// Fontes de evidência realmente usadas nesta conclusão.
  final Set<GeometryEvidenceSource> evidence;

  final GeometryShapeIdentity? shape;

  /// Extras da operação. **Não** são evidência: nunca sustentam aprovação.
  final Map<String, Object?> attributes;

  bool get isFailure => status == GeometryOutcomeStatus.failure;

  /// Só é verdadeiro com evidência completa (validação + pós-condições).
  bool get isValidatedSuccess =>
      (status == GeometryOutcomeStatus.successChanged &&
          validity.checked &&
          !validity.hasErrors &&
          postConditions.isNotEmpty &&
          postConditions.every((item) => item.satisfied) &&
          metrics.any((item) => item.isBrep)) ||
      (status == GeometryOutcomeStatus.successUnchanged &&
          postConditions.isNotEmpty &&
          postConditions.every((item) => item.satisfied) &&
          idempotence != GeometryIdempotence.changeExpected);

  /// Precisa de verificação/humano antes de virar aprovação.
  bool get requiresVerification =>
      status == GeometryOutcomeStatus.notVerified ||
      !postConditions.every((item) => item.satisfied) ||
      (status == GeometryOutcomeStatus.successChanged && !validity.checked);

  bool get isRepairUnchanged =>
      status == GeometryOutcomeStatus.successUnchanged &&
      idempotence == GeometryIdempotence.repairsMayBeUnchanged;

  Iterable<GeometryOutcomeDiagnostic> get errors =>
      diagnostics.where((item) => item.isError);

  Map<String, Object?> toJson() => {
    'operation': operation,
    'operationClass': operationClass.name,
    'status': status.name,
    'execution': execution.name,
    'idempotence': idempotence.name,
    'statePolicy': statePolicy.name,
    'validity': validity.toJson(),
    'postConditions': postConditions.map((item) => item.toJson()).toList(),
    'metrics': metrics.map((item) => item.toJson()).toList(),
    'diagnostics': diagnostics.map((item) => item.toJson()).toList(),
    'evidence': evidence.map((item) => item.name).toList()..sort(),
    if (shape != null) 'shape': shape!.toJson(),
    if (attributes.isNotEmpty) 'attributes': attributes,
  };

  factory GeometryOutcome.fromJson(Map<String, Object?> json) =>
      GeometryOutcome._(
        operation: json['operation']! as String,
        operationClass: GeometryOperationClass.values.byName(
          json['operationClass']! as String,
        ),
        status: GeometryOutcomeStatus.values.byName(json['status']! as String),
        execution: GeometryExecutionStatus.values.byName(
          json['execution']! as String,
        ),
        idempotence: GeometryIdempotence.values.byName(
          json['idempotence']! as String,
        ),
        statePolicy: OriginalStatePolicy.values.byName(
          json['statePolicy']! as String,
        ),
        validity: GeometryValidityReport.fromJson(
          (json['validity']! as Map).cast<String, Object?>(),
        ),
        postConditions: [
          for (final item in (json['postConditions']! as List))
            GeometryPostConditionReport.fromJson(
              (item as Map).cast<String, Object?>(),
            ),
        ],
        metrics: [
          for (final item in (json['metrics']! as List))
            GeometryMetricEvidence.fromJson(
              (item as Map).cast<String, Object?>(),
            ),
        ],
        diagnostics: [
          for (final item in (json['diagnostics']! as List))
            GeometryOutcomeDiagnostic.fromJson(
              (item as Map).cast<String, Object?>(),
            ),
        ],
        evidence: {
          for (final item in (json['evidence']! as List).cast<String>())
            GeometryEvidenceSource.values.byName(item),
        },
        shape: json['shape'] == null
            ? null
            : GeometryShapeIdentity.fromJson(
                (json['shape']! as Map).cast<String, Object?>(),
              ),
        attributes:
            (json['attributes'] as Map?)?.cast<String, Object?>() ?? const {},
      );

  @override
  String toString() =>
      'GeometryOutcome($operation: ${status.name}, exec=${execution.name}, '
      'evidencia=${evidence.length}, diagnostico=${diagnostics.length})';
}
