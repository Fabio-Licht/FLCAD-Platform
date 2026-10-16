import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_derived_edge_classifier.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_silhouette_classifier.dart';
import 'package:flcad_mobile/app/cad_viewport/rendering/mesh_triangle_topology.dart';

void main() {
  test('topologia compartilhada preserva welding e incidência', () {
    final vertices = <num>[
      0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0,
      0, 0, 0, // duplicate vertex, intentionally welded
    ];
    final triangles = <num>[0, 1, 2, 0, 2, 3];
    final topology = const MeshTriangleTopologyBuilder().build(
      vertices: vertices,
      triangles: triangles,
    );
    expect(topology.statistics.validTriangles, 2);
    expect(topology.statistics.weldedVertices, 4);
    expect(topology.edges, hasLength(5));
    expect(topology.edges.first.faces, isNotEmpty);
    expect(vertices[0], 0);
    expect(triangles[0], 0);
  });

  test('classificadores compartilham contagem estrutural da topologia', () {
    final vertices = <num>[
      -1,
      -1,
      -1,
      1,
      -1,
      -1,
      1,
      1,
      -1,
      -1,
      1,
      -1,
      -1,
      -1,
      1,
      1,
      -1,
      1,
      1,
      1,
      1,
      -1,
      1,
      1,
    ];
    final triangles = <num>[
      0,
      1,
      2,
      0,
      2,
      3,
      4,
      6,
      5,
      4,
      7,
      6,
      0,
      4,
      5,
      0,
      5,
      1,
      3,
      2,
      6,
      3,
      6,
      7,
      0,
      3,
      7,
      0,
      7,
      4,
      1,
      5,
      6,
      1,
      6,
      2,
    ];
    final mesh = const MeshDerivedEdgeClassifier().classify(
      vertices: vertices,
      triangles: triangles,
    );
    final silhouette = const MeshSilhouetteClassifier().classify(
      vertices: vertices,
      triangles: triangles,
      camera: const MeshSilhouetteCamera(
        eye: [4, 4, 6],
        target: [0, 0, 0],
        up: [0, 1, 0],
      ),
    );
    final topology = const MeshTriangleTopologyBuilder().build(
      vertices: vertices,
      triangles: triangles,
    );
    expect(
      mesh.statistics.inputTriangles,
      silhouette.statistics.inputTriangles,
    );
    expect(
      mesh.statistics.validTriangles,
      silhouette.statistics.validTriangles,
    );
    expect(
      mesh.statistics.weldedVertices,
      silhouette.statistics.weldedVertices,
    );
    expect(mesh.statistics.uniqueCandidateEdges, 18);
    expect(
      topology.statistics.uniqueCandidateEdges,
      mesh.statistics.uniqueCandidateEdges,
    );
  });
}
