import '../feature_lifecycle/feature_update_solver.dart';
import '../parametric_solver/parametric_solver.dart';

enum ProfessionalExtrudeSourceKind { sketch, surface }

enum ProfessionalExtrudeDirection { normal, reverse }

enum ProfessionalExtrudeOutput { solid, surface }

enum ProfessionalExtrudeExtent {
  distance,
  symmetric,
  throughAllPrepared,
  upToSurfacePrepared,
}

class ProfessionalExtrudeContract {
  const ProfessionalExtrudeContract({
    required this.sourceEntityId,
    required this.sourceKind,
    required this.sourceRevision,
    required this.sourceShapeId,
    required this.distance,
    this.profileEntityId,
    this.profileEntityIds = const [],
    this.draftAngleDegrees = 0,
    this.directionSourceId = 'profileNormal',
    this.directionVector = const [0, 0, 1],
    this.direction = ProfessionalExtrudeDirection.normal,
    this.output = ProfessionalExtrudeOutput.solid,
    this.extent = ProfessionalExtrudeExtent.distance,
  });
  final String sourceEntityId, sourceShapeId;
  final ProfessionalExtrudeSourceKind sourceKind;
  final int sourceRevision;
  final double distance;
  final String? profileEntityId;

  /// Ordered Sketch entities used by a real multi-profile Extrude. The legacy
  /// singular field remains the compatibility anchor for one profile.
  final List<String> profileEntityIds;
  final double draftAngleDegrees;
  final String directionSourceId;
  final List<double> directionVector;
  final ProfessionalExtrudeDirection direction;
  final ProfessionalExtrudeOutput output;
  final ProfessionalExtrudeExtent extent;
  bool get reverse => direction == ProfessionalExtrudeDirection.reverse;
  Map<String, dynamic> toJson() => {
    'sourceEntityId': sourceEntityId,
    'sourceKind': sourceKind.name,
    'sourceRevision': sourceRevision,
    'sourceShapeId': sourceShapeId,
    'distance': distance,
    if (profileEntityId != null) 'profileEntityId': profileEntityId,
    if (profileEntityIds.isNotEmpty) 'profileEntityIds': profileEntityIds,
    'draftAngleDegrees': draftAngleDegrees,
    'directionSourceId': directionSourceId,
    'directionVector': directionVector,
    'direction': direction.name,
    'output': output.name,
    'extent': extent.name,
    'symmetricSupported': true,
    'throughAllSupported': false,
    'upToSurfaceSupported': false,
    'arbitraryVectorPrepared': true,
  };
  factory ProfessionalExtrudeContract.fromJson(Map<String, dynamic> json) =>
      ProfessionalExtrudeContract(
        sourceEntityId: json['sourceEntityId'] as String,
        sourceKind: ProfessionalExtrudeSourceKind.values.byName(
          json['sourceKind'] as String,
        ),
        sourceRevision: (json['sourceRevision'] as num).toInt(),
        sourceShapeId: json['sourceShapeId'] as String,
        distance: (json['distance'] as num).toDouble(),
        profileEntityId: json['profileEntityId'] as String?,
        profileEntityIds: (json['profileEntityIds'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        draftAngleDegrees: (json['draftAngleDegrees'] as num?)?.toDouble() ?? 0,
        directionSourceId:
            json['directionSourceId'] as String? ?? 'profileNormal',
        directionVector: (json['directionVector'] as List? ?? const [0, 0, 1])
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(growable: false),
        direction: ProfessionalExtrudeDirection.values.byName(
          json['direction'] as String? ?? 'normal',
        ),
        output: ProfessionalExtrudeOutput.values.byName(
          json['output'] as String? ?? 'solid',
        ),
        extent: ProfessionalExtrudeExtent.values.byName(
          json['extent'] as String? ?? 'distance',
        ),
      );
}

class ProfessionalExtrudeHealth {
  const ProfessionalExtrudeHealth(
    this.profile,
    this.distance,
    this.direction,
    this.ready,
    this.message,
  );
  final bool profile, distance, direction, ready;
  final String message;
  Map<String, dynamic> toJson() => {
    'profile': profile,
    'distance': distance,
    'direction': direction,
    'ready': ready,
    'message': message,
  };
}

class ProfessionalExtrudeConstraintAdapter {
  const ProfessionalExtrudeConstraintAdapter({
    this.featureUpdates = const FeatureUpdateSolver(),
  });
  final FeatureUpdateSolver featureUpdates;
  ParametricMotionPlan solve(ProfessionalExtrudeContract value) {
    if (value.sourceEntityId.isEmpty || value.sourceShapeId.isEmpty) {
      throw ArgumentError('Extrude requires one persistent Sketch or Surface.');
    }
    if (!value.distance.isFinite || value.distance <= 0) {
      throw ArgumentError('Extrude distance must be greater than zero.');
    }
    if (!value.draftAngleDegrees.isFinite ||
        value.draftAngleDegrees.abs() >= 89) {
      throw ArgumentError(
        'Extrude draft angle must be finite and greater than -89° and less than 89°.',
      );
    }
    if (value.directionVector.length != 3 ||
        value.directionVector.any((component) => !component.isFinite) ||
        value.directionVector.every((component) => component.abs() <= 1e-12)) {
      throw ArgumentError(
        'Extrude direction vector must be finite and non-zero.',
      );
    }
    if (!{
      ProfessionalExtrudeExtent.distance,
      ProfessionalExtrudeExtent.symmetric,
    }.contains(value.extent)) {
      throw UnsupportedError(
        'This Extrude extent is prepared but not implemented.',
      );
    }
    return featureUpdates.update(
      request: ParametricSolveRequest(
        first: value.sourceEntityId,
        second: 'extrude.distance',
        degreesOfFreedom: [
          ParametricDegreeOfFreedom(value.sourceEntityId),
          ParametricDegreeOfFreedom('extrude.distance'),
        ],
        restrictions: [
          ParametricRestriction('extrude.source', {value.sourceEntityId}),
        ],
        priorities: [
          ParametricPriority(value.sourceEntityId, 0),
          const ParametricPriority('extrude.distance', 1),
        ],
        preferredAnchor: value.sourceEntityId,
      ),
      apply: (plan) => plan,
    );
  }

  ProfessionalExtrudeHealth health(ProfessionalExtrudeContract value) {
    try {
      solve(value);
      return const ProfessionalExtrudeHealth(
        true,
        true,
        true,
        true,
        'Extrude is ready.',
      );
    } on Object catch (error) {
      return ProfessionalExtrudeHealth(
        value.sourceShapeId.isNotEmpty,
        value.distance > 0,
        true,
        false,
        '$error',
      );
    }
  }

  /// Turns a native Draft failure into a user-facing diagnostic without
  /// changing the original kernel result.  The OCCT bridge reports topology
  /// failures as text, while parameter validation remains local to [solve].
  static String diagnosticForKernelFailure(
    Object error, {
    required double draftAngleDegrees,
  }) {
    final message = error.toString().replaceFirst('Bad state: ', '');
    final normalized = message.toLowerCase();
    // Profile/topology validation runs locally, before the native Draft task.
    // When it fails, the real cause must win even if a Draft angle is present,
    // otherwise an open profile would be mislabelled as a generic kernel Draft
    // failure.
    final isProfileFailure =
        normalized.contains('perfil') ||
        normalized.contains('abert') ||
        normalized.contains('fechado') ||
        normalized.contains('gap') ||
        normalized.contains('incompleto') ||
        normalized.contains('wire');
    if (isProfileFailure) return message;
    if (draftAngleDegrees.abs() <= 1e-9) return message;
    if (normalized.contains('extrude draft angle must')) {
      return 'Valor de Draft inválido: $message';
    }
    if (normalized.contains('draft angle requires') ||
        normalized.contains('draft angle found') ||
        normalized.contains('draft angle could not')) {
      return 'Draft falhou para a topologia deste perfil: $message';
    }
    return 'Extrude com Draft falhou no kernel: $message';
  }
}

abstract final class ProfessionalExtrudeNaming {
  static String nextId(Iterable<String> ids) {
    final used = ids.toSet();
    var index = 1;
    while (used.contains('Extrude${index.toString().padLeft(3, '0')}')) {
      index++;
    }
    return 'Extrude${index.toString().padLeft(3, '0')}';
  }
}
