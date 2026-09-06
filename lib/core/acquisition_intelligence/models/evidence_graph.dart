import '../../metric_reference/models/metric_reference.dart';

enum EvidenceNodeKind { capture, analysis, recommendation, metricReference }

enum EvidenceRelation { supports, measures, suggests }

class EvidenceNode {
  const EvidenceNode({
    required this.id,
    required this.kind,
    required this.payload,
  });

  final String id;
  final EvidenceNodeKind kind;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'payload': payload,
  };

  factory EvidenceNode.fromJson(Map<String, dynamic> json) => EvidenceNode(
    id: json['id'] as String,
    kind: EvidenceNodeKind.values.byName(json['kind'] as String),
    payload: Map<String, dynamic>.from(json['payload'] as Map),
  );
}

class EvidenceEdge {
  const EvidenceEdge({
    required this.from,
    required this.to,
    required this.relation,
  });

  final String from;
  final String to;
  final EvidenceRelation relation;

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'relation': relation.name,
  };

  factory EvidenceEdge.fromJson(Map<String, dynamic> json) => EvidenceEdge(
    from: json['from'] as String,
    to: json['to'] as String,
    relation: EvidenceRelation.values.byName(json['relation'] as String),
  );
}

class EvidenceGraph {
  const EvidenceGraph({this.nodes = const [], this.edges = const []});

  final List<EvidenceNode> nodes;
  final List<EvidenceEdge> edges;

  EvidenceGraph addCapture({
    required String captureId,
    required Map<String, dynamic> capture,
    required Map<String, dynamic> evidence,
  }) {
    final evidenceId = 'evidence:$captureId';
    final nextNodes = [
      ...nodes,
      EvidenceNode(
        id: 'capture:$captureId',
        kind: EvidenceNodeKind.capture,
        payload: capture,
      ),
      EvidenceNode(
        id: evidenceId,
        kind: EvidenceNodeKind.analysis,
        payload: evidence,
      ),
    ];
    return EvidenceGraph(
      nodes: nextNodes,
      edges: [
        ...edges,
        EvidenceEdge(
          from: 'capture:$captureId',
          to: evidenceId,
          relation: EvidenceRelation.supports,
        ),
      ],
    );
  }

  EvidenceGraph addMetricReference({
    required MetricReference reference,
    required Iterable<MetricReferenceEvidence> evidence,
  }) {
    final referenceNodeId = 'metric-reference:${reference.id}';
    final evidenceNodeId = 'metric-evidence:${reference.id}';
    final evidencePayload = {
      'referenceId': reference.id,
      'items': evidence.map((item) => item.toJson()).toList(),
    };
    return EvidenceGraph(
      nodes: [
        ...nodes,
        EvidenceNode(
          id: referenceNodeId,
          kind: EvidenceNodeKind.metricReference,
          payload: reference.toJson(),
        ),
        EvidenceNode(
          id: evidenceNodeId,
          kind: EvidenceNodeKind.analysis,
          payload: evidencePayload,
        ),
      ],
      edges: [
        ...edges,
        EvidenceEdge(
          from: referenceNodeId,
          to: evidenceNodeId,
          relation: EvidenceRelation.measures,
        ),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'nodes': nodes.map((e) => e.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
  };

  factory EvidenceGraph.fromJson(Map<String, dynamic> json) => EvidenceGraph(
    nodes: (json['nodes'] as List<dynamic>? ?? const [])
        .map(
          (node) =>
              EvidenceNode.fromJson(Map<String, dynamic>.from(node as Map)),
        )
        .toList(),
    edges: (json['edges'] as List<dynamic>? ?? const [])
        .map(
          (edge) =>
              EvidenceEdge.fromJson(Map<String, dynamic>.from(edge as Map)),
        )
        .toList(),
  );
}
