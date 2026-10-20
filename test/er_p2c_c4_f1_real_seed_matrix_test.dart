import 'dart:io';
import 'dart:typed_data';

import 'package:flcad_mobile/app/engineering_bridge/contracts/bridge_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/cylindrical_region_selector.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/editable_surface_selection.dart';
import 'package:flcad_mobile/app/engineering_bridge/selection/mesh_region_builder.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/geometric_recognition/models/recognition_models.dart';
import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/professional_recognition/recognizers/quadric_recognizers.dart';
import 'package:flcad_mobile/core/professional_recognition/engine/professional_recognition_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ER-P2C-C4-F1 real cylinder seed matrix is auditable',
    () async {
      const path =
          r'C:\flcad_mobile\test_assets\real_meshes\PARCIAL_FURO_18MM.stl';
      final file = File(path);
      expect(file.existsSync(), isTrue);
      final parsed = _parseStl(file);
      final welded = _weld(parsed.vertices, parsed.triangles);
      final geometry = KernelMeshGeometry(
        nodes: welded.vertices,
        triangles: welded.triangles,
      );
      final source = EditableSurfaceSelection(
        projectId: 'c4-f1',
        meshId: 'fixture',
        meshFingerprint:
            '79CBC79911400F760C3A76FFB485BD01E515B43DAB14B31B3AC435B5D0243BE3',
        entityId: 'fixture',
        geometry: geometry,
        initialTriangles: {32065},
        area: 0,
      );
      final first = _run(geometry, source, 32065);
      final directedWatch = Stopwatch()..start();
      final directed = await ProfessionalRecognitionEngine().recognize(
        [
          RecognitionContext(
            observation: RecognitionObservation(
              projectId: 'c4-f1',
              meshId: 'fixture',
              regionId: 'directed-cyl-32065',
              points: first.region.points,
              normals: first.region.normals,
              meshFingerprint:
                  '79CBC79911400F760C3A76FFB485BD01E515B43DAB14B31B3AC435B5D0243BE3',
              regionFingerprint: 'directed-cyl-32065',
            ),
          ),
        ],
        allowedTypes: {PrimitiveType.cylinder},
      );
      directedWatch.stop();
      final selected = first.selection.triangles.toList()..sort();
      final seeds = <int>{
        32065,
        ...source.neighborsOf(32065).take(6),
        98952,
        ...source.neighborsOf(98952).take(6),
        110610,
        ...source.neighborsOf(110610).take(6),
        for (final fraction in const [.1, .25, .5, .75, .9])
          selected[(selected.length * fraction).floor().clamp(
            0,
            selected.length - 1,
          )],
      };
      final rows = <String>[
        'ER-P2C-C4-F1 real cylinder seed matrix',
        'fixture=$path',
        'sha256=79CBC79911400F760C3A76FFB485BD01E515B43DAB14B31B3AC435B5D0243BE3',
        'input_bytes=${file.lengthSync()}',
        'input_triangles=${geometry.triangles.length ~/ 3}',
        'reference_seed=32065',
        'reference_selected=${first.selection.triangles.length}',
        'reference_transitions=${first.selection.transitionTriangles.length}',
        'reference_radius=${first.selection.radius}',
        'reference_axis=${first.selection.axis.toJson()}',
        'reference_origin=${first.selection.origin.toJson()}',
        'directed_engine_ms=${directedWatch.elapsedMicroseconds / 1000} '
            'directed_audit_entries=${directed.primitives.first.auditTrail.length} '
            'directed_first_pass=${directed.primitives.first.auditTrail.first}',
      ];
      var recovered110610 = false;
      var diagnosed98952 = false;
      for (final seed in seeds) {
        final row = _run(geometry, source, seed);
        final p = row.candidate.parameters;
        final s = row.candidate.statistics;
        final center = _triangleCenter(geometry, seed);
        final normal = _triangleNormal(geometry, seed);
        final axial = (center - first.selection.origin).dot(
          first.selection.axis,
        );
        final referenceRadial =
            (center - (first.selection.origin + first.selection.axis * axial))
                .length;
        rows.add(
          'seed=$seed '
          'contains_seed=${row.selection.triangles.contains(seed)} '
          'selected=${row.selection.triangles.length} '
          'excluded=${geometry.triangles.length ~/ 3 - row.selection.triangles.length} '
          'transitions=${row.selection.transitionTriangles.length} '
          'points=${row.region.points.length} '
          'diameter=${p['diameter']} '
          'radius=${p['radius']} '
          'angular=${s.angularCoverageDegrees} '
          'rms=${s.rms} '
          'maximum=${s.maximum} '
          'conditioning=${s.conditioning} '
          'stability=${s.axisStability} '
          'quality=${s.qualityStatus} '
          'converged=${s.converged} '
          'reference_radial_delta=${(referenceRadial - first.selection.radius).abs()} '
          'reference_normal_axis=${normal.dot(first.selection.axis).abs()} '
          'local=${row.selection.diagnostics['localSeedTriangles']} '
          'normal_conditioning=${row.selection.diagnostics['normalConditioning']} '
          'c2_radius=${row.selection.diagnostics['radiusMm']} '
          'c2_rms=${row.selection.diagnostics['rmsCentroidResidualMm']} '
          'c2_max=${row.selection.diagnostics['maximumCentroidResidualMm']} '
          'c2_tolerance=${row.selection.diagnostics['radialToleranceMm']} '
          'broad=${row.selection.diagnostics['broadTopologyTriangles']} '
          'axis_aligned=${row.selection.diagnostics['axisAlignedTriangles']} '
          'local_model_radius=${row.selection.diagnostics['localModelRadiusMm']} '
          'broad_model_radius=${row.selection.diagnostics['broadModelRadiusMm']} '
          'scales=${row.selection.diagnostics['scaleDiagnostics']} '
          'hypotheses=${row.selection.diagnostics['hypothesisCount']} '
          'chosen_scale=${row.selection.diagnostics['chosenHypothesisScale']} '
          'chosen_score=${row.selection.diagnostics['chosenHypothesisScore']} '
          'chosen_coverage=${row.selection.diagnostics['chosenHypothesisCoverage']} '
          'chosen_rms=${row.selection.diagnostics['chosenHypothesisRms']} '
          'hypothesis_quality=${row.selection.diagnostics['hypothesisQuality']} '
          'hypothesis_ms=${row.selection.diagnostics['hypothesisEvaluationMs']} '
          'hypothesis_diagnostics=${row.selection.diagnostics['hypothesisDiagnostics']} '
          'c2_ms=${row.c2Ms.toStringAsFixed(3)} '
          'c3_ms=${row.c3Ms.toStringAsFixed(3)}',
        );
        if (seed == 110610) {
          recovered110610 =
              row.selection.triangles.length > 20000 &&
              (p['diameter']! as num) > 17.5;
        }
        if (seed == 98952) {
          diagnosed98952 =
              row.selection.diagnostics['hypothesisQuality'] ==
              'insufficient-local-evidence';
        }
      }
      final report = File(
        r'C:\flcad_mobile\artifacts\ER-P2C-C4-F1-windows-debug\ER-P2C-C4-F1-seed-matrix.txt',
      )..parent.createSync(recursive: true);
      report.writeAsStringSync('${rows.join('\n')}\n');
      stdout.write(report.readAsStringSync());
      expect(seeds.length, greaterThanOrEqualTo(4));
      expect(first.selection.triangles, contains(32065));
      expect(first.candidate.parameters['diameter'], isA<num>());
      expect(recovered110610, isTrue);
      expect(diagnosed98952, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Vector3 _triangleCenter(KernelMeshGeometry geometry, int triangle) {
  final offset = triangle * 3;
  final a = _vertex(geometry, geometry.triangles[offset]);
  final b = _vertex(geometry, geometry.triangles[offset + 1]);
  final c = _vertex(geometry, geometry.triangles[offset + 2]);
  return (a + b + c) / 3;
}

Vector3 _triangleNormal(KernelMeshGeometry geometry, int triangle) {
  final offset = triangle * 3;
  final a = _vertex(geometry, geometry.triangles[offset]);
  final b = _vertex(geometry, geometry.triangles[offset + 1]);
  final c = _vertex(geometry, geometry.triangles[offset + 2]);
  return (b - a).cross(c - a).normalized;
}

Vector3 _vertex(KernelMeshGeometry geometry, int index) {
  final offset = index * 3;
  return Vector3(
    geometry.nodes[offset],
    geometry.nodes[offset + 1],
    geometry.nodes[offset + 2],
  );
}

({
  CylindricalRegionSelectionResult selection,
  MeshRegion region,
  RecognitionCandidate candidate,
  double c2Ms,
  double c3Ms,
})
_run(KernelMeshGeometry geometry, EditableSurfaceSelection source, int seed) {
  final c2 = Stopwatch()..start();
  final selection = const CylindricalRegionSelector().select(
    geometry: geometry,
    seedTriangle: seed,
    neighborsOf: source.neighborsOf,
  );
  c2.stop();
  final region = const MeshRegionBuilder().build(
    meshId: 'fixture',
    selection: BridgeSelection(
      id: 'c4-f1-$seed',
      entityId: 'fixture',
      kind: BridgeSelectionKind.meshRegion,
      geometry: geometry,
      triangleIndices: selection.triangles,
    ),
  );
  final c3 = Stopwatch()..start();
  final candidate = const CylinderProfessionalRecognizer().evaluate(
    RecognitionContext(
      observation: RecognitionObservation(
        projectId: 'c4-f1',
        meshId: 'fixture',
        regionId: 'c4-f1-$seed',
        points: region.points,
        normals: region.normals,
        meshFingerprint:
            '79CBC79911400F760C3A76FFB485BD01E515B43DAB14B31B3AC435B5D0243BE3',
        regionFingerprint: 'c4-f1-$seed',
      ),
    ),
  );
  c3.stop();
  return (
    selection: selection,
    region: region,
    candidate: candidate,
    c2Ms: c2.elapsedMicroseconds / 1000,
    c3Ms: c3.elapsedMicroseconds / 1000,
  );
}

({List<double> vertices, List<int> triangles}) _parseStl(File file) {
  final bytes = file.readAsBytesSync();
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

({List<double> vertices, List<int> triangles}) _weld(
  List<double> vertices,
  List<int> triangles,
) {
  final unique = <String, int>{};
  final weldedVertices = <double>[];
  final weldedTriangles = <int>[];
  for (final sourceIndex in triangles) {
    final offset = sourceIndex * 3;
    final key = [
      for (var axis = 0; axis < 3; axis++)
        (vertices[offset + axis] * 1000000).round(),
    ].join(':');
    final index = unique.putIfAbsent(key, () {
      final next = weldedVertices.length ~/ 3;
      weldedVertices.addAll(vertices.sublist(offset, offset + 3));
      return next;
    });
    weldedTriangles.add(index);
  }
  return (vertices: weldedVertices, triangles: weldedTriangles);
}
