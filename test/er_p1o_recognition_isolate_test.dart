import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flcad_mobile/app/cad_viewport/scene/cad_scene_graph.dart';
import 'package:flcad_mobile/app/cad_viewport/selection/viewport_picking_controller.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/technical_stl_pick_resolver.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/import_export/api/import_export_api.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/surface_recognition/models/surface_recognition_models.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capturing mesh wrappers in Isolate.run is unsendable', () async {
    final geometry = _unsendablePlane();
    await expectLater(
      Isolate.run(
        () => runRegionGrowingInIsolate(
          regionGrowingIsolatePayload(
            geometry: geometry,
            fingerprint: 'captured',
            settings: const SurfaceRecognitionSettings(minimumTriangles: 1),
          ),
        ),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.toString(),
          'message',
          contains('unsendable'),
        ),
      ),
    );
  });

  test(
    'recognizePick uses TechnicalStl resolver then a sendable Region Growing worker',
    () async {
      final geometry = _unsendablePlane();
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'stl-plane',
      );
      addTearDown(session.dispose);

      await session.controller.recognizePick(
        pick: const CadViewportPick(
          entityId: 'stl-plane',
          hit: MeshHit(triangleIndex: 0, point: Vector3(1, 1, 0), distance: 10),
          ray: MeshRay(Vector3(1, 1, 10), Vector3(0, 0, -1)),
        ),
        allowTechnicalStl: true,
      );

      expect(session.controller.error ?? '', isNot(contains('unsendable')));
      expect(session.resolverHits, 1);
      expect(
        session.controller.report,
        isNotNull,
        reason: session.controller.error,
      );
      expect(session.controller.hypotheses, isNotEmpty);
    },
  );

  test(
    'CALOTA_INOXX.stl smoke through recognizePick has no isolate error',
    () async {
      const path = r'C:\flcad_mobile\test_assets\real_meshes\CALOTA_INOXX.stl';
      final file = File(path);
      expect(file.existsSync(), isTrue);
      final parsed = _parseStl(file);
      final geometry = KernelMeshGeometry(
        nodes: parsed.vertices,
        triangles: parsed.triangles,
      );
      const seed = 0;
      final ray = _rayForTriangle(geometry, seed);
      final session = await _RecognitionSession.open(
        geometry: geometry,
        entityId: 'calota',
      );
      addTearDown(session.dispose);

      final stopwatch = Stopwatch()..start();
      await session.controller.recognizePick(
        pick: CadViewportPick(
          entityId: 'calota',
          hit: MeshHit(triangleIndex: seed, point: ray.origin, distance: 1),
          ray: ray,
        ),
        allowTechnicalStl: true,
      );
      stopwatch.stop();

      expect(session.controller.error ?? '', isNot(contains('unsendable')));
      expect(session.resolverHits, 1);
      expect(
        session.controller.report,
        isNotNull,
        reason: session.controller.error,
      );
      expect(session.controller.hypotheses, isNotEmpty);

      final winner = session.controller.hypotheses.first.recognition.winner;
      final diagnostics =
          session.cad.runtime.read<Map>('recognition.planarDiagnostics') ??
          const {};
      final report = StringBuffer()
        ..writeln('ER-P1O CALOTA isolate smoke')
        ..writeln('head=a5a3972245a9f662a097af5cc827a8c502491ad9')
        ..writeln('fixture=$path')
        ..writeln('triangles=${geometry.triangles.length ~/ 3}')
        ..writeln('seed=$seed')
        ..writeln('isolate_error=none')
        ..writeln('winner=${winner.type.name}')
        ..writeln('rms=${winner.statistics.rms}')
        ..writeln('max=${winner.statistics.maximum}')
        ..writeln('planarClassification=${diagnostics['planarClassification']}')
        ..writeln('selectedTriangles=${diagnostics['selectedTriangles']}')
        ..writeln('processing_ms=${stopwatch.elapsedMilliseconds}')
        ..writeln('gui_capture=not performed');
      final out = File(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P1O\er_p1o_report.txt',
      );
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(report.toString());
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

final class _RecognitionSession {
  _RecognitionSession({
    required this.cad,
    required this.controller,
    required this.entityId,
  });

  final DesktopCadController cad;
  final OperationalReverseEngineeringController controller;
  final String entityId;
  int resolverHits = 0;

  static Future<_RecognitionSession> open({
    required KernelMeshGeometry geometry,
    required String entityId,
  }) async {
    final cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager.instance,
    );
    final commands = DesktopCommandCoordinator(
      cad: cad,
      projects: ProjectManager.instance,
    );
    final runtimeDirectory = await Directory.systemTemp.createTemp(
      'flcad-er-p1o-',
    );
    await cad.runtime.open('project', runtimeDirectory);
    final triangleCount = geometry.triangles.length ~/ 3;
    final vertexCount = geometry.nodes.length ~/ 3;
    await cad.runtime.registerImport(
      ImportedCadDocument(
        id: entityId,
        projectId: 'project',
        sourcePath: '$entityId.stl',
        format: CadImportFormat.stl,
        registeredPath: 'CAD/$entityId.stl',
        validation: const [],
        mesh: KernelMeshHandle(
          persistentId: entityId,
          kernelId: 'kernel',
          fingerprint: entityId,
          vertexCount: vertexCount,
          triangleCount: triangleCount,
          bounds: const KernelBounds(0, 0, 0, 1, 1, 1),
          hasNormals: false,
          metadata: const {},
        ),
      ),
    );
    final imported = cad.runtime.document!.entities[entityId]!;
    cad.runtime.debugPutEntity(
      CadDocumentEntity(
        id: imported.id,
        kind: imported.kind,
        mesh: imported.mesh,
        placement: imported.placement,
        data: {
          ...imported.data,
          'managedStlAssets': {'displayMeshSha256': 'sha-$entityId'},
        },
      ),
    );
    cad.runtime.scene.upsert(
      CadSceneEntity(
        id: entityId,
        kind: CadSceneEntityKind.mesh,
        geometry: {
          'presentationLod': {'triangles': triangleCount},
        },
      ),
    );
    late final _RecognitionSession session;
    final resolver = TechnicalStlPickResolver(
      null,
      entityProvider: (_) => CadDocumentEntity(
        id: imported.id,
        kind: CadDocumentEntityKind.import,
        data: {
          'managedStlAssets': {'displayMeshSha256': 'sha-$entityId'},
        },
      ),
      geometryLoader: (_) async {
        session.resolverHits++;
        return geometry;
      },
    );
    final controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
      technicalStlPickResolver: resolver,
    );
    session = _RecognitionSession(
      cad: cad,
      controller: controller,
      entityId: entityId,
    );
    session._runtimeDirectory = runtimeDirectory;
    return session;
  }

  late final Directory _runtimeDirectory;

  Future<void> dispose() async {
    controller.dispose();
    cad.dispose();
    await _runtimeDirectory.delete(recursive: true);
  }
}

KernelMeshGeometry _unsendablePlane() {
  final nodes = <double>[];
  final triangles = <int>[];
  const rows = 6;
  const columns = 6;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      nodes.addAll([x.toDouble(), y.toDouble(), 0]);
    }
  }
  for (var y = 0; y < rows - 1; y++) {
    for (var x = 0; x < columns - 1; x++) {
      final a = y * columns + x;
      final b = a + 1;
      final c = a + columns + 1;
      final d = a + columns;
      triangles
        ..addAll([a, b, c])
        ..addAll([a, c, d]);
    }
  }
  return KernelMeshGeometry(
    nodes: _UnsendableList<double>(nodes),
    triangles: _UnsendableList<int>(triangles),
  );
}

MeshRay _rayForTriangle(KernelMeshGeometry geometry, int triangleIndex) {
  final offset = triangleIndex * 3;
  Vector3 vertex(int index) {
    final cursor = geometry.triangles[index] * 3;
    return Vector3(
      geometry.nodes[cursor],
      geometry.nodes[cursor + 1],
      geometry.nodes[cursor + 2],
    );
  }

  final a = vertex(offset);
  final b = vertex(offset + 1);
  final c = vertex(offset + 2);
  final centroid = Vector3(
    (a.x + b.x + c.x) / 3,
    (a.y + b.y + c.y) / 3,
    (a.z + b.z + c.z) / 3,
  );
  var normal = (b - a).cross(c - a);
  final length = normal.length;
  normal = length <= 1e-12 ? const Vector3(0, 0, 1) : normal / length;
  return MeshRay(
    centroid + normal * 10,
    Vector3(-normal.x, -normal.y, -normal.z),
  );
}

final class _UnsendableList<E> extends ListBase<E> {
  _UnsendableList(this._values);

  final List<E> _values;
  final Future<void> _keepAlive = Future<void>.value();

  @override
  int get length => _values.length;

  @override
  set length(int newLength) => _values.length = newLength;

  @override
  E operator [](int index) {
    _keepAlive;
    return _values[index];
  }

  @override
  void operator []=(int index, E value) => _values[index] = value;
}

({List<double> vertices, List<int> triangles}) _parseStl(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length >= 6) {
    final prefix = String.fromCharCodes(bytes.take(5));
    if (prefix.toLowerCase() == 'solid' &&
        (bytes.length < 84 || !_looksBinary(bytes))) {
      return _parseAscii(bytes);
    }
  }
  return _parseBinary(bytes);
}

bool _looksBinary(Uint8List bytes) {
  if (bytes.length < 84) return false;
  final count = ByteData.sublistView(bytes).getUint32(80, Endian.little);
  return count > 0 && bytes.length >= 84 + count * 50;
}

({List<double> vertices, List<int> triangles}) _parseBinary(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = data.getUint32(80, Endian.little);
  final vertices = List<double>.filled(count * 9, 0);
  final triangles = List<int>.generate(count * 3, (index) => index);
  var cursor = 84;
  var offset = 0;
  for (var face = 0; face < count; face++) {
    cursor += 12;
    for (var corner = 0; corner < 3; corner++) {
      vertices[offset] = data.getFloat32(cursor, Endian.little);
      vertices[offset + 1] = data.getFloat32(cursor + 4, Endian.little);
      vertices[offset + 2] = data.getFloat32(cursor + 8, Endian.little);
      offset += 3;
      cursor += 12;
    }
    cursor += 2;
  }
  return (vertices: vertices, triangles: triangles);
}

({List<double> vertices, List<int> triangles}) _parseAscii(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final vertices = <double>[];
  final triangles = <int>[];
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('vertex')) {
      final parts = line.split(RegExp(r'\s+'));
      vertices.addAll([
        double.parse(parts[1]),
        double.parse(parts[2]),
        double.parse(parts[3]),
      ]);
      triangles.add(triangles.length);
    }
  }
  return (vertices: vertices, triangles: triangles);
}
