import 'dart:io';

import 'package:flcad_mobile/core/cad_kernel/commands/fel_kernel_commands.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_bridge.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_adapter.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_kernel_plugin.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_runtime_repository.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_studio_integration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'plugin registers, initializes and unloads through KernelManager',
    () async {
      final bridge = _RecordingBridge();
      final manager = KernelManager();
      OpenCascadeKernelPlugin(bridge: bridge).register(manager);
      final health = await manager.select('opencascade');
      expect(health.status, KernelHealthStatus.healthy);
      expect(manager.active.descriptor.version, '7.8.1');
      expect(
        manager.active.descriptor.capabilities.values,
        containsAll([KernelCapability.step, KernelCapability.planeSurface]),
      );
      await manager.unload('opencascade');
      expect(bridge.shutdownCalled, isTrue);
    },
  );

  test(
    'unavailable native host fails explicitly and preserves fallback',
    () async {
      // Deterministic by construction: an explicitly unavailable bridge, never
      // the process PATH or a staged OCCT runtime. The real native host is
      // verified separately, opt-in, below.
      final manager = KernelManager();
      OpenCascadeKernelPlugin(
        bridge: const UnavailableOpenCascadeBridge('native host unavailable'),
      ).register(manager);
      await expectLater(manager.select('opencascade'), throwsStateError);
      expect(manager.active.descriptor.id, 'opencascade');
      expect(
        (await manager.healthCheck()).status,
        KernelHealthStatus.unavailable,
      );
    },
  );

  test('registration does not load or initialize the native bridge', () async {
    final bridge = _RecordingBridge();
    var loads = 0;
    final adapter = OpenCascadeKernelAdapter(
      bridgeFactory: () {
        loads++;
        return bridge;
      },
    );
    final manager = KernelManager()..register(adapter, makeDefault: true);

    expect(loads, 0);
    expect(bridge.initializeCalled, isFalse);
    expect(manager.active.descriptor.version, 'uninitialized');

    await adapter.create(
      'CREATE VERTEX',
      const {'x': 0.0, 'y': 0.0, 'z': 0.0},
      persistentId: 'lazy-vertex',
      expectedType: CADShapeType.vertex,
      transaction: KernelTransaction(
        'lazy-tx',
        'project',
        'opencascade',
        DateTime(2026),
        TransactionStatus.active,
        const [],
      ),
    );
    expect(loads, 1);
    expect(bridge.initializeCalled, isTrue);
  });

  test(
    'STEP and IGES import return opaque handles with no native token',
    () async {
      final bridge = _RecordingBridge();
      final adapter = OpenCascadeKernelAdapter(bridge: bridge);
      await adapter.initialize();
      final step = await adapter.importFile(
        'part.step',
        KernelExchangeFormat.step,
        projectId: 'project',
      );
      final iges = await adapter.importFile(
        'part.igs',
        KernelExchangeFormat.iges,
        projectId: 'project',
      );
      expect([step.type, iges.type], [CADShapeType.solid, CADShapeType.solid]);
      expect(step.fingerprint, 'sha256:test');
      expect(step.toJson().toString(), isNot(contains('TopoDS')));
      expect(bridge.imports, ['step:part.step', 'iges:part.igs']);
    },
  );

  test(
    'export validation healing sewing and meshing route only through bridge',
    () async {
      final bridge = _RecordingBridge();
      final adapter = OpenCascadeKernelAdapter(bridge: bridge);
      await adapter.initialize();
      final handle = await adapter.importFile(
        'part.brep',
        KernelExchangeFormat.brep,
        projectId: 'p',
      );
      await adapter.exportFile(handle, 'out.step', KernelExchangeFormat.step);
      expect(await adapter.diagnose(handle), hasLength(1));
      expect(await adapter.proposeHealing(handle), hasLength(1));
      final shell = await adapter.sew(
        [handle],
        projectId: 'p',
        tolerance: 0.01,
      );
      expect(shell.type, CADShapeType.shell);
      final mesh = await adapter.mesh(
        handle,
        outputPath: 'mesh.bin',
        deflection: 0.1,
      );
      expect([mesh.vertexCount, mesh.triangleCount], [3, 1]);
      expect(bridge.exports, ['step:out.step']);
      expect(adapter.runtime.analytics.operations, 6);
    },
  );

  test('FEL registers real OCC command surface', () {
    final names = createKernelFELCommands().map((e) => e.name);
    expect(
      names,
      containsAll([
        'IMPORT STEP',
        'IMPORT IGES',
        'EXPORT STEP',
        'EXPORT IGES',
        'VALIDATE GEOMETRY',
        'HEAL GEOMETRY',
        'SHOW KERNEL VERSION',
        'SHOW KERNEL STATUS',
        'CREATE PLANE',
        'CREATE CYLINDER',
        'VALIDATE SHAPE',
        'HEAL SHAPE',
      ]),
    );
  });

  test('FFI loader reports a missing native library without fabrication', () {
    expect(OpenCascadeFFI.tryLoad(path: 'definitely-missing-occt.dll'), isNull);
    expect(
      () => OpenCascadeFFI.load(path: 'definitely-missing-occt.dll'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('OpenCascade DLL is unavailable'),
        ),
      ),
    );
  });

  test('vertex gets a persistent ID and releases its native shape', () async {
    final bridge = _RecordingBridge();
    final adapter = OpenCascadeKernelAdapter(bridge: bridge);
    await adapter.initialize();
    final handle = await adapter.create(
      'CREATE VERTEX',
      const {'x': 0.0, 'y': 0.0, 'z': 0.0},
      persistentId: 'project-vertex-1',
      expectedType: CADShapeType.vertex,
      transaction: KernelTransaction(
        'tx-1',
        'project',
        'opencascade',
        DateTime(2026),
        TransactionStatus.active,
        const [],
      ),
    );
    expect(handle.persistentId, 'project-vertex-1');
    expect(handle.type, CADShapeType.vertex);
    await adapter.destroy(handle);
    expect(bridge.destroyed, ['created-vertex']);
  });

  test(
    'professional surface operation returns native handle and reversible tokens',
    () async {
      final bridge = _RecordingBridge();
      final adapter = OpenCascadeKernelAdapter(bridge: bridge);
      final source = await adapter.importFile(
        'surface.brep',
        KernelExchangeFormat.brep,
        projectId: 'project',
      );
      final result = await adapter.executeSurfaceOperation(
        source,
        'healSurface',
        const {},
        projectId: 'project',
      );
      expect(result.supported, isTrue);
      expect(result.result?.kernelId, 'opencascade');
      await adapter.rollbackSurfaceOperation(result.undoToken!);
      await adapter.redoSurfaceOperation(result.redoToken!);
      expect(bridge.surfaceOperations, ['HEAL']);
    },
  );

  test('native BREP persistence restores persistent identity', () async {
    final bridge = _RecordingBridge();
    final adapter = OpenCascadeKernelAdapter(bridge: bridge);
    final source = await adapter.importFile(
      'surface.brep',
      KernelExchangeFormat.brep,
      projectId: 'project',
    );
    await adapter.persistShape(source, 'cache/surface.brep');
    final restored = await adapter.restoreShape(
      'cache/surface.brep',
      persistentId: source.persistentId,
    );
    expect(restored.persistentId, source.persistentId);
    expect(restored.type, CADShapeType.solid);
    expect(bridge.exports, contains('brep:cache/surface.brep'));
  });

  test('native metadata repository creates project-first structure', () async {
    final root = await Directory.systemTemp.createTemp('flcad-occ-');
    addTearDown(() => root.delete(recursive: true));
    const repository = OpenCascadeRuntimeRepository();
    final handle = ShapeHandle.reference(
      persistentId: 'shape-1',
      kernelId: 'opencascade',
      type: CADShapeType.face,
      metadata: {'topoDSType': 'face'},
    );
    final file = await repository.saveShapeMetadata(root, handle);
    expect(await file.exists(), isTrue);
    for (final folder in const [
      'Kernel',
      'KernelCache',
      'KernelDiagnostics',
      'NativeShapes',
    ]) {
      expect(
        await Directory(
          '${root.path}${Platform.pathSeparator}$folder',
        ).exists(),
        isTrue,
      );
    }
  });

  test('Studio exposes kernel status and portable inspector context', () async {
    final manager = KernelManager();
    OpenCascadeKernelPlugin(bridge: _RecordingBridge()).register(manager);
    await manager.select('opencascade');
    final snapshot = await const OpenCascadeStudioIntegration().inspect(
      manager,
    );
    final node = snapshot.toTreeNode('project');
    expect(node.context['kernelId'], 'opencascade');
    expect(node.context['kernelVersion'], '7.8.1');
    expect(node.context.toString(), isNot(contains('TopoDS_Shape')));
  });

  // Real native host verification, separated from the deterministic scenario
  // above. It is opt-in: without FLCAD_OCC_REQUIRE_NATIVE=1 it is a BLOCKED
  // skip (never an approval), so the suite stays green on machines without the
  // OCCT runtime while still allowing an explicit fail when someone demands it.
  final requireNativeHost =
      (Platform.environment['FLCAD_OCC_REQUIRE_NATIVE'] ?? '') == '1';
  test(
    'real OCCT host creates and releases a native shape (opt-in)',
    () async {
      final bridge = OpenCascadeFFI.loadOrUnavailable();
      if (bridge is! OpenCascadeFFI) {
        fail('FLCAD_OCC_REQUIRE_NATIVE=1 requires a loadable OCCT runtime');
      }
      final adapter = OpenCascadeKernelAdapter(bridge: bridge);
      final handle = await adapter.create(
        'CREATE VERTEX',
        const {'x': 0.0, 'y': 0.0, 'z': 0.0},
        persistentId: 'native-vertex-probe',
        expectedType: CADShapeType.vertex,
        transaction: KernelTransaction(
          'tx-native-probe',
          'project',
          'opencascade',
          DateTime(2026),
          TransactionStatus.active,
          const [],
        ),
      );
      expect(handle.kernelId, 'opencascade');
      expect(handle.persistentId, 'native-vertex-probe');
      await adapter.destroy(handle);
      await adapter.unload();
    },
    skip: requireNativeHost
        ? false
        : 'opt-in: set FLCAD_OCC_REQUIRE_NATIVE=1 with the OCCT runtime staged',
  );
}

class _RecordingBridge
    implements OpenCascadeNativeBridge, OpenCascadeSurfaceNativeBridge {
  final imports = <String>[];
  final exports = <String>[];
  bool shutdownCalled = false;
  bool initializeCalled = false;
  final destroyed = <String>[];
  final surfaceOperations = <String>[];
  @override
  Future<void> initialize() async => initializeCalled = true;
  @override
  Future<void> shutdown() async => shutdownCalled = true;
  @override
  Future<String> version() async => '7.8.1';
  @override
  Future<Set<String>> capabilities() async => {
    'STEP',
    'IGES',
    'BREP',
    'Surface',
    'Meshing',
    'Healing',
  };
  @override
  Future<Map<String, dynamic>> diagnostics() async => {'healthy': true};
  @override
  Future<OpenCascadeNativeShape> createShape(
    String operation,
    Map<String, dynamic> parameters,
    CADShapeType expectedType,
  ) async => OpenCascadeNativeShape(
    token: 'created-${expectedType.name}',
    type: expectedType,
    fingerprint: 'sha256:${expectedType.name}',
  );
  @override
  Future<void> destroyShape(String nativeToken) async =>
      destroyed.add(nativeToken);
  @override
  Future<OpenCascadeNativeShape> transformShape(
    String nativeToken,
    List<double> matrix, {
    bool copyGeometry = true,
  }) async => OpenCascadeNativeShape(
    token: '$nativeToken-transformed',
    type: CADShapeType.solid,
    fingerprint: 'sha256:transformed',
  );
  @override
  Future<OpenCascadeNativeShape> importShape(
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async {
    imports.add('${format.name}:$path');
    return const OpenCascadeNativeShape(
      token: 'TopoDS-private-token',
      type: CADShapeType.solid,
      fingerprint: 'sha256:test',
      metadata: {'source': 'native'},
    );
  }

  @override
  Future<void> exportShape(
    String nativeToken,
    String path,
    KernelExchangeFormat format, {
    required KernelCancellationToken cancellation,
    void Function(KernelProgress progress)? onProgress,
  }) async {
    expect(nativeToken, 'TopoDS-private-token');
    exports.add('${format.name}:$path');
  }

  @override
  Future<List<GeometryDiagnostic>> validate(String nativeToken) async => const [
    GeometryDiagnostic(
      code: 'open-shell',
      message: 'Shell is open',
      severity: 'warning',
    ),
  ];
  @override
  Future<List<HealingProposal>> proposeHealing(String nativeToken) async =>
      const [
        HealingProposal(
          id: 'h1',
          operation: 'fix-shape',
          reason: 'Open shell',
          diagnostics: [],
        ),
      ];
  @override
  Future<OpenCascadeNativeShape> sew(
    List<String> nativeTokens,
    double tolerance,
  ) async => const OpenCascadeNativeShape(
    token: 'shell-token',
    type: CADShapeType.shell,
    fingerprint: 'sha256:shell',
  );
  @override
  Future<KernelMeshData> mesh(
    String nativeToken,
    String outputPath,
    double deflection,
  ) async => KernelMeshData(3, 1, outputPath);
  @override
  Future<Map<String, dynamic>> inspectSurfaceTopology(
    String nativeToken,
  ) async => const {'boundaries': [], 'loops': []};
  @override
  Future<Map<String, dynamic>> intersectSurfaces(
    String firstToken,
    String secondToken,
  ) async => const {'edgeCount': 0, 'length': 0.0};

  @override
  Future<Map<String, dynamic>> inspectSurfaceQuality(
    String nativeToken, {
    required List<double> draftDirection,
    required int samples,
  }) async => const {
    'minimumCurvature': 0.0,
    'maximumCurvature': 0.0,
    'averageMinimumCurvature': 0.0,
    'averageMaximumCurvature': 0.0,
    'meanCurvature': 0.0,
    'gaussianCurvature': 0.0,
    'curvatureGradient': 0.0,
    'curvatureStability': 1.0,
    'averageNormal': [0.0, 0.0, 1.0],
    'reflectionScore': 1.0,
    'zebra': {'horizontal': 1.0, 'vertical': 1.0, 'radial': 1.0, 'free': 1.0},
    'draft': {
      'minimumAngle': 90.0,
      'maximumAngle': 90.0,
      'negative': 0,
      'critical': 0,
      'approved': 1,
    },
  };

  @override
  Future<OpenCascadeNativeShape> executeSurfaceOperation(
    String operation, {
    String? sourceToken,
    List<String> referenceTokens = const [],
    List<double> values = const [],
  }) async {
    surfaceOperations.add(operation);
    return OpenCascadeNativeShape(
      token: 'surface-${surfaceOperations.length}',
      type: CADShapeType.face,
      fingerprint: 'surface-$operation',
      metadata: {'operator': operation},
    );
  }
}
