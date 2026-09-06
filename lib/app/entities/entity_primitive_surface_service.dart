import 'dart:math' as math;

import '../../core/cad_document/cad_document.dart';
import '../../core/cad_kernel/models/kernel_models.dart';
import '../../core/cad_kernel/transactions/kernel_transaction_manager.dart';
import '../../core/geometric_kernel/geometry/vectors.dart';
import '../cad_viewport/scene/cad_scene_graph.dart';
import '../runtime/cad_runtime.dart';

enum PrimitiveSurfaceType { plane, cylinder, cone, sphere, torus }

class EntityPrimitiveSurfaceService {
  EntityPrimitiveSurfaceService(this.runtime);
  final CadRuntime runtime;

  Future<String> create({
    required PrimitiveSurfaceType type,
    Vector3 origin = Vector3.zero,
    Vector3 direction = const Vector3(0, 0, 1),
    double radius = 10,
    double majorRadius = 20,
    double minorRadius = 5,
    double height = 20,
    double semiAngleDegrees = 30,
    double planeSize = 100,
    double sphereLatitudeStartDegrees = -90,
    double sphereLatitudeEndDegrees = 90,
  }) async {
    final document = runtime.document;
    if (document == null) {
      throw StateError('Abra um projeto antes de criar superfícies.');
    }
    _validate(
      type,
      direction: direction,
      radius: radius,
      majorRadius: majorRadius,
      minorRadius: minorRadius,
      height: height,
      semiAngleDegrees: semiAngleDegrees,
      planeSize: planeSize,
      latitudeStart: sphereLatitudeStartDegrees,
      latitudeEnd: sphereLatitudeEndDegrees,
    );
    final kernel = runtime.kernels.active;
    final capability = switch (type) {
      PrimitiveSurfaceType.plane => KernelCapability.planeSurface,
      PrimitiveSurfaceType.cylinder => KernelCapability.cylinderSurface,
      PrimitiveSurfaceType.cone => KernelCapability.coneSurface,
      PrimitiveSurfaceType.sphere => KernelCapability.sphereSurface,
      PrimitiveSurfaceType.torus => KernelCapability.torusSurface,
    };
    final health = await kernel.healthCheck();
    if (health.status == KernelHealthStatus.unavailable ||
        !kernel.descriptor.capabilities.supports(capability)) {
      throw StateError(
        'O kernel ${kernel.descriptor.name} não suporta superfície ${type.name}.',
      );
    }
    final unitDirection = direction.normalized;
    final parameters = _parameters(
      type,
      origin: origin,
      direction: unitDirection,
      radius: radius,
      majorRadius: majorRadius,
      minorRadius: minorRadius,
      height: height,
      semiAngleDegrees: semiAngleDegrees,
      planeSize: planeSize,
      latitudeStart: sphereLatitudeStartDegrees,
      latitudeEnd: sphereLatitudeEndDegrees,
    );
    final id = 'surface:${type.name}:${DateTime.now().microsecondsSinceEpoch}';
    final transactions = KernelTransactionManager(kernel);
    final transaction = await transactions.begin(document.projectId);
    ShapeHandle shape;
    List<String> diagnostics;
    try {
      shape = await kernel.create(
        'GENERATE ${type.name.toUpperCase()}',
        parameters,
        persistentId: '$id:shape',
        expectedType: CADShapeType.face,
        transaction: transaction,
      );
      diagnostics = await kernel.validate(shape, const {
        'geometry',
        'bounds',
        'orientation',
        'degeneration',
      });
      final fatal = diagnostics.where((item) {
        final text = item.toLowerCase();
        return text.contains('error') ||
            text.contains('invalid') ||
            text.contains('failed');
      }).toList();
      if (fatal.isNotEmpty) {
        throw StateError('Validação geométrica falhou: ${fatal.join('; ')}');
      }
      await transactions.commit(transaction.id);
    } catch (_) {
      await transactions.rollback(transaction.id);
      rethrow;
    }
    final number =
        1 +
        document.entities.values.where((entity) {
          final contract = entity.data['constructionEntity'];
          return entity.kind == CadDocumentEntityKind.surface &&
              contract is Map &&
              contract['type'] == 'primitiveSurface';
        }).length;
    await runtime.upsertEntity(
      command: 'entities.surface.${type.name}',
      kind: CadDocumentEntityKind.surface,
      shape: shape,
      entity: CadSceneEntity(
        id: id,
        kind: CadSceneEntityKind.surface,
        geometry: {
          'surfaceKind': type.name,
          'parameters': parameters,
          'displayColor': 'definitiveSurface',
          'shaded': true,
        },
      ),
      data: {
        'name': '${_label(type)} $number',
        'collectionId': 'collection:modified',
        'constructionEntity': {
          'type': 'primitiveSurface',
          'primitive': type.name,
          'method': 'manualParameters',
          'parameters': parameters,
          'meshRequired': false,
          'diagnostics': diagnostics,
        },
        'surfaceKind': type.name,
        'authoringRoot': true,
        'workspace': 'Entidades',
      },
    );
    runtime.geometrySelection.select(id);
    return id;
  }

  Map<String, dynamic> _parameters(
    PrimitiveSurfaceType type, {
    required Vector3 origin,
    required Vector3 direction,
    required double radius,
    required double majorRadius,
    required double minorRadius,
    required double height,
    required double semiAngleDegrees,
    required double planeSize,
    required double latitudeStart,
    required double latitudeEnd,
  }) => switch (type) {
    PrimitiveSurfaceType.plane => {
      'origin': origin.toJson(),
      'normal': direction.toJson(),
      'lowerBound': -planeSize / 2,
      'upperBound': planeSize / 2,
      'width': planeSize,
      'height': planeSize,
    },
    PrimitiveSurfaceType.cylinder => {
      'axisOrigin': origin.toJson(),
      'axisDirection': direction.toJson(),
      'radius': radius,
      'lowerBound': 0.0,
      'upperBound': height,
    },
    PrimitiveSurfaceType.cone => {
      'apex': origin.toJson(),
      'axisDirection': direction.toJson(),
      'semiAngle': semiAngleDegrees * math.pi / 180,
      'semiAngleDegrees': semiAngleDegrees,
      'lowerBound': 0.0,
      'upperBound': height,
    },
    PrimitiveSurfaceType.sphere => {
      'center': origin.toJson(),
      'radius': radius,
      'lowerBound': latitudeStart * math.pi / 180,
      'upperBound': latitudeEnd * math.pi / 180,
    },
    PrimitiveSurfaceType.torus => {
      'center': origin.toJson(),
      'axisDirection': direction.toJson(),
      'majorRadius': majorRadius,
      'minorRadius': minorRadius,
    },
  };

  void _validate(
    PrimitiveSurfaceType type, {
    required Vector3 direction,
    required double radius,
    required double majorRadius,
    required double minorRadius,
    required double height,
    required double semiAngleDegrees,
    required double planeSize,
    required double latitudeStart,
    required double latitudeEnd,
  }) {
    if (direction.length <= 1e-12) {
      throw StateError('A direção/normal não pode ser zero.');
    }
    if (type == PrimitiveSurfaceType.plane && planeSize <= 0) {
      throw StateError('O tamanho do plano deve ser positivo.');
    }
    if ({
          PrimitiveSurfaceType.cylinder,
          PrimitiveSurfaceType.sphere,
        }.contains(type) &&
        radius <= 0) {
      throw StateError('O raio deve ser positivo.');
    }
    if ({
          PrimitiveSurfaceType.cylinder,
          PrimitiveSurfaceType.cone,
        }.contains(type) &&
        height <= 0) {
      throw StateError('A altura deve ser positiva.');
    }
    if (type == PrimitiveSurfaceType.cone &&
        (semiAngleDegrees <= 0 || semiAngleDegrees >= 90)) {
      throw StateError('O semiângulo do cone deve estar entre 0° e 90°.');
    }
    if (type == PrimitiveSurfaceType.sphere &&
        (latitudeStart < -90 ||
            latitudeEnd > 90 ||
            latitudeStart >= latitudeEnd)) {
      throw StateError(
        'Os limites da esfera devem satisfazer -90° ≤ início < fim ≤ 90°.',
      );
    }
    if (type == PrimitiveSurfaceType.torus &&
        (majorRadius <= 0 || minorRadius <= 0 || majorRadius <= minorRadius)) {
      throw StateError(
        'No toro, o raio maior deve ser maior que o raio menor positivo.',
      );
    }
  }

  String _label(PrimitiveSurfaceType type) => switch (type) {
    PrimitiveSurfaceType.plane => 'Plane Surface',
    PrimitiveSurfaceType.cylinder => 'Cylinder Surface',
    PrimitiveSurfaceType.cone => 'Cone Surface',
    PrimitiveSurfaceType.sphere => 'Sphere Surface',
    PrimitiveSurfaceType.torus => 'Torus Surface',
  };
}
