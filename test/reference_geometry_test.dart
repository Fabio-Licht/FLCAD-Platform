import 'dart:io';
import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/core/cad_kernel/api/geometry_kernel_api.dart';
import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/geometric_kernel/precision/precision.dart';
import 'package:flcad_mobile/core/acquisition_intelligence/models/evidence_graph.dart';
import 'package:flcad_mobile/core/metric_reference/metric_reference.dart'
    as metric;
import 'package:flcad_mobile/core/reference_geometry/analytics/reference_analytics.dart';
import 'package:flcad_mobile/core/reference_geometry/api/reference_api.dart';
import 'package:flcad_mobile/core/reference_geometry/commands/fel_reference_commands.dart';
import 'package:flcad_mobile/core/reference_geometry/history/reference_history.dart';
import 'package:flcad_mobile/core/reference_geometry/integration/reference_factory.dart';
import 'package:flcad_mobile/core/reference_geometry/integration/reference_studio.dart';
import 'package:flcad_mobile/core/reference_geometry/models/reference_models.dart';
import 'package:flcad_mobile/core/reference_geometry/repository/reference_repository.dart';
import 'package:flcad_mobile/core/reference_geometry/runtime/reference_runtime.dart';
import 'package:flcad_mobile/core/reference_geometry/validation/reference_validation.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReferenceContractKernel implements GeometryKernelAPI {
  _ReferenceContractKernel({this.supported = true, this.available = true});
  final bool supported, available;
  int creates = 0, begins = 0, commits = 0, rollbacks = 0;
  @override
  KernelDescriptor get descriptor => KernelDescriptor(
    id: 'reference-contract',
    name: 'Reference contract kernel',
    version: '1',
    vendor: 'test',
    capabilities: KernelCapabilities({
      if (supported) KernelCapability.planeSurface,
    }),
  );
  @override
  Future<KernelHealth> healthCheck() async => KernelHealth(
    available ? KernelHealthStatus.healthy : KernelHealthStatus.unavailable,
    available ? 'ready' : 'offline',
    DateTime.now(),
  );
  @override
  Future<void> begin(KernelTransaction transaction) async => begins++;
  @override
  Future<void> commit(KernelTransaction transaction) async => commits++;
  @override
  Future<void> rollback(KernelTransaction transaction) async => rollbacks++;
  @override
  Future<ShapeHandle> create(
    String operation,
    Map<String, dynamic> parameters, {
    required String persistentId,
    required CADShapeType expectedType,
    required KernelTransaction transaction,
  }) async {
    creates++;
    expect(operation, 'REFERENCE_GEOMETRY');
    return ShapeHandle.reference(
      persistentId: persistentId,
      kernelId: descriptor.id,
      type: expectedType,
      fingerprint: 'kernel-owned-reference',
    );
  }

  @override
  Future<List<String>> validate(ShapeHandle handle, Set<String> checks) async =>
      const [];
  @override
  Future<void> unload() async {}
}

void main() {
  late Directory project;
  setUp(
    () async =>
        project = await Directory.systemTemp.createTemp('flcad_reference_'),
  );
  tearDown(() async {
    if (await project.exists()) await project.delete(recursive: true);
  });
  ReferenceApi make(GeometryKernelAPI kernel) => const ReferenceFactory()
      .create(projectDirectory: project, projectId: 'project', kernel: kernel);
  ReferenceEntity datum(
    ReferenceApi api,
    ReferenceType type, {
    int index = 0,
  }) => api.builder.build(
    type: type,
    method: switch (type) {
      ReferenceType.datumPlane ||
      ReferenceType.constructionPlane => ReferenceMethod.xyz,
      ReferenceType.datumAxis ||
      ReferenceType.constructionAxis => ReferenceMethod.vectorAxis,
      ReferenceType.datumPoint ||
      ReferenceType.constructionPoint => ReferenceMethod.xyz,
      ReferenceType.coordinateSystem => ReferenceMethod.origin,
      _ => ReferenceMethod.group,
    },
    name: '${type.name} $index',
  );

  test('ten reference contracts and construction methods are parametric', () {
    expect(ReferenceType.values, hasLength(10));
    expect(ReferenceMethod.values.length, greaterThanOrEqualTo(20));
    final api = make(_ReferenceContractKernel());
    for (final type in ReferenceType.values) {
      expect(datum(api, type).output, isNull);
    }
    expect(api.references, hasLength(10));
  });

  test('preview reports reference metadata without kernel geometry', () {
    final kernel = _ReferenceContractKernel(),
        api = make(kernel),
        entity = datum(api, ReferenceType.datumPlane),
        preview = api.preview(entity.id);
    expect(preview.kind, 'datumPlane');
    expect(preview.readiness, isTrue);
    expect(preview.bounds.width, 10);
    expect(entity.output, isNull);
    expect(kernel.creates, 0);
  });

  test(
    'official adapter transaction is the exclusive execution path',
    () async {
      final kernel = _ReferenceContractKernel(),
          api = make(kernel),
          entity = datum(api, ReferenceType.datumPlane),
          result = await api.confirm(entity.id);
      expect(result.success, isTrue);
      expect(result.shape?.fingerprint, 'kernel-owned-reference');
      expect(result.shape?.type, CADShapeType.face);
      expect(
        [kernel.creates, kernel.begins, kernel.commits, kernel.rollbacks],
        [1, 1, 1, 0],
      );
    },
  );

  test('kernel unavailable and unsupported states produce no shape', () async {
    final unavailable = _ReferenceContractKernel(available: false),
        unsupported = _ReferenceContractKernel(supported: false),
        a = make(unavailable),
        b = make(unsupported);
    expect(
      (await a.confirm(datum(a, ReferenceType.datumPlane).id)).status,
      ReferenceStatus.kernelUnavailable,
    );
    expect(
      (await b.confirm(datum(b, ReferenceType.datumPlane).id)).status,
      ReferenceStatus.unsupportedOperation,
    );
    expect(unavailable.creates + unsupported.creates, 0);
  });

  test(
    'validation detects missing references intersections axes and points',
    () {
      final api = make(_ReferenceContractKernel()),
          missing = api.builder.build(
            type: ReferenceType.datumPlane,
            method: ReferenceMethod.threePoints,
            name: 'missing',
          ),
          axis = api.builder.build(
            type: ReferenceType.datumAxis,
            method: ReferenceMethod.vectorAxis,
            name: 'axis',
            parameters: ReferenceParameters(
              direction: const ReferenceVector(0, 0, 0),
            ),
          ),
          point = api.builder.build(
            type: ReferenceType.datumPoint,
            method: ReferenceMethod.xyz,
            name: 'point',
            parameters: ReferenceParameters(
              origin: const ReferenceVector(double.nan, 0, 0),
            ),
          ),
          intersection = api.builder.build(
            type: ReferenceType.datumAxis,
            method: ReferenceMethod.planeIntersection,
            name: 'intersection',
            input: ReferenceInput(referenceIds: const ['one']),
          );
      expect(
        api.validate(missing.id).issues.map((e) => e.type),
        contains(ReferenceIssueType.missingReference),
      );
      expect(
        api.validate(axis.id).issues.map((e) => e.type),
        contains(ReferenceIssueType.degenerateAxis),
      );
      expect(
        api.validate(point.id).issues.map((e) => e.type),
        contains(ReferenceIssueType.invalidPoint),
      );
      expect(
        api.validate(intersection.id).issues.map((e) => e.type),
        contains(ReferenceIssueType.invalidIntersection),
      );
    },
  );

  test(
    'editing lifecycle preserves freeze suppression groups and identity',
    () {
      final api = make(_ReferenceContractKernel()),
          entity = datum(api, ReferenceType.datumPlane),
          id = entity.id;
      api.engine.rename(id, 'Primary');
      api.engine.move(id, 7);
      api.engine.group(id, 'group');
      api.engine.setVisibility(id, false);
      api.engine.suppress(id, true);
      api.engine.suppress(id, false);
      api.engine.freeze(id, true);
      expect(
        () => api.engine.edit(id, (e) => e.name = 'blocked'),
        throwsStateError,
      );
      api.engine.freeze(id, false);
      expect(entity.id, id);
      expect(entity.name, 'Primary');
      expect(entity.order, 7);
      expect(entity.groupId, 'group');
      expect(entity.visible, isFalse);
      expect(entity.frozen, isFalse);
      expect(api.engine.undo(), isTrue);
      expect(api.engine.redo(), isTrue);
    },
  );

  test('1000 planes axes points and coordinate systems remain unique', () {
    final api = make(_ReferenceContractKernel());
    for (var i = 0; i < 1000; i++) {
      datum(api, ReferenceType.datumPlane, index: i);
      datum(api, ReferenceType.datumAxis, index: i);
      datum(api, ReferenceType.datumPoint, index: i);
      datum(api, ReferenceType.coordinateSystem, index: i);
    }
    expect(api.references, hasLength(4000));
    expect(api.references.map((e) => e.id).toSet(), hasLength(4000));
    expect(api.engine.analytics.planes, 1000);
    expect(api.engine.analytics.axes, 1000);
    expect(api.engine.analytics.points, 1000);
    expect(api.engine.analytics.coordinateSystems, 1000);
  });

  test(
    '1000 rebuild dependency and visibility updates remain stable',
    () async {
      final kernel = _ReferenceContractKernel(),
          api = make(kernel),
          parent = datum(api, ReferenceType.datumPlane),
          target = datum(api, ReferenceType.datumAxis);
      for (var i = 0; i < 1000; i++) {
        expect((await api.rebuild(target.id)).success, isTrue);
        api.engine.addDependency(target.id, parent.id);
        api.engine.setVisibility(target.id, i.isEven);
      }
      expect(kernel.creates, 1000);
      expect(api.engine.analytics.rebuilds, 1000);
      expect(api.engine.analytics.dependencyUpdates, 1000);
      expect(api.engine.analytics.visibilityChanges, 1000);
      expect(api.engine.graph.downstream(parent.id), contains(target.id));
    },
  );

  test(
    'repository workspace Studio FEL advisor and bootstrap integrate',
    () async {
      final api = make(_ReferenceContractKernel()),
          entity = datum(api, ReferenceType.coordinateSystem);
      api.preview(entity.id);
      await api.engine.persist();
      for (final path in ReferenceRepository.paths) {
        expect(
          Directory(
            '${project.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}',
          ).existsSync(),
          isTrue,
        );
      }
      expect(ReferenceStudioAdapter.workspace, 'Reverse Engineering Workspace');
      expect(ReferenceStudioAdapter.panels, hasLength(4));
      expect(
        ReferenceStudioAdapter()
            .buildTree(api.engine, 'project')
            .last
            .context['referenceGeometry'],
        isTrue,
      );
      expect(createReferenceFelCommands(api).length, greaterThanOrEqualTo(60));
      expect(api.recommendations(entity.id).single.confidence, greaterThan(0));
      EngineeringBootstrap.instance.initialize();
      expect(
        EngineeringBootstrap.instance.services.get<ReferenceRuntime>(),
        isNotNull,
      );
      expect(
        EngineeringBootstrap.instance.services.get<ReferenceHistory>(),
        isNotNull,
      );
      expect(
        EngineeringBootstrap.instance.services.get<ReferenceAnalytics>(),
        isNotNull,
      );
    },
  );

  group('M-005 Metric Reference System', () {
    test(
      'runs marker, bar, distance, object, solver and persistence flow',
      () async {
        final capturedAt = DateTime.utc(2026, 8, 22);
        final marker = metric.fiducialMarker(
          id: 'Marker001',
          nominalSize: 20,
          material: metric.FiducialMaterial.pvc,
        );
        final bar = metric.ScaleBar.calibrated(
          id: 'ScaleBar001',
          millimeters: 100,
        );
        final sphere = metric.CalibratedReferenceObject(
          id: 'ReferenceSphere001',
          shape: metric.CalibratedObjectShape.sphere,
          nominalDimension: 40,
          unit: LengthUnit.millimeter,
        );
        final knownDistance = metric.MetricReference(
          id: 'KnownDistance001',
          type: metric.MetricReferenceType.distance,
          pointA: Vector3.zero,
          pointB: const Vector3(25, 0, 0),
          knownValue: 50,
          unit: LengthUnit.millimeter,
          createdAt: capturedAt,
        );
        final system = metric.MetricReferenceSystem();
        system.addAll([
          marker.toReference(
            pointA: Vector3.zero,
            pointB: const Vector3(10, 0, 0),
            measuredSize: 10,
            capturedAt: capturedAt,
          ),
          bar.toReference(
            pointA: Vector3.zero,
            pointB: const Vector3(50, 0, 0),
            capturedAt: capturedAt,
          ),
          knownDistance,
          sphere.toReference(
            pointA: Vector3.zero,
            pointB: const Vector3(20, 0, 0),
            measuredType: metric.MetricReferenceType.diameter,
            capturedAt: capturedAt,
          ),
        ]);
        final solution = system.solve();
        final graph = system.evidenceGraph();
        final directory = await Directory.systemTemp.createTemp('m005-');
        addTearDown(() => directory.delete(recursive: true));
        final repository = metric.MetricReferenceRepository(
          directory: directory,
        );

        await repository.save(
          metric.MetricReferenceSnapshot(
            projectId: 'm005-project',
            references: system.references,
            solution: solution,
          ),
        );
        final reopened = await repository.load('m005-project');

        expect(marker.hasValidChecksum, isTrue);
        expect(system.references, hasLength(4));
        expect(solution.evidence, hasLength(4));
        expect(solution.maximumResidual, greaterThanOrEqualTo(0));
        expect(graph.nodes, hasLength(8));
        expect(
          graph.nodes.where(
            (node) => node.kind == EvidenceNodeKind.metricReference,
          ),
          hasLength(4),
        );
        expect(
          reopened!.references.map((item) => item.id),
          containsAll([
            'Marker001',
            'ScaleBar001',
            'KnownDistance001',
            'ReferenceSphere001',
          ]),
        );
        expect(reopened.solution.evidence, hasLength(4));
        expect(reopened.solution.confidence, solution.confidence);
      },
    );
  });
}
