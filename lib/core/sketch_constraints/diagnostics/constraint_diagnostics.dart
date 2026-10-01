enum ConstraintDiagnosticKind {
  conflict,
  missingReference,
  brokenReference,
  circularDependency,
  duplicate,
  redundant,
  overConstraint,
  underConstraint,
  failure,
}

class ConstraintDiagnostic {
  const ConstraintDiagnostic(
    this.kind,
    this.message, {
    this.constraintIds = const [],
    this.suggestedFix,
  });
  final ConstraintDiagnosticKind kind;
  final String message;
  final List<String> constraintIds;
  final String? suggestedFix;
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'message': message,
    'constraintIds': constraintIds,
    'suggestedFix': suggestedFix,
  };
}

class SolverStatistics {
  const SolverStatistics({
    required this.executionTime,
    required this.iterations,
    required this.solved,
    required this.failed,
    this.failureReason,
  });
  final Duration executionTime;
  final int iterations;
  final int solved;
  final int failed;
  final String? failureReason;
}

class ConstraintSolveResult {
  const ConstraintSolveResult({
    required this.statistics,
    required this.diagnostics,
    required this.solvedIds,
  });
  final SolverStatistics statistics;
  final List<ConstraintDiagnostic> diagnostics;
  final Set<String> solvedIds;
  bool get success => diagnostics.every(
    (d) =>
        d.kind != ConstraintDiagnosticKind.conflict &&
        d.kind != ConstraintDiagnosticKind.duplicate &&
        d.kind != ConstraintDiagnosticKind.overConstraint &&
        d.kind != ConstraintDiagnosticKind.failure &&
        d.kind != ConstraintDiagnosticKind.missingReference &&
        d.kind != ConstraintDiagnosticKind.circularDependency,
  );
}
