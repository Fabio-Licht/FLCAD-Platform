import '../../../core/cad_document/cad_document.dart';
import '../../runtime/cad_runtime.dart';
import '../layout/panel_identity.dart';
import 'panel_protocol.dart';
import 'panel_view_model.dart';

/// Authoritative main-process state a panel projects.
///
/// The bridge never talks to `CadRuntime`, `ProjectManager` or the command
/// registry directly: it only uses this contract, which reads snapshots without
/// mutating anything and applies the two whitelisted mutations through the
/// session's own APIs. That is what keeps a *single* CAD controller alive.
abstract class PanelSessionSource {
  String? get projectId;

  /// Runtime session identity (changes when the Workspace/runtime session is
  /// replaced, e.g. after a project switch).
  int get sessionId;

  /// Diagnostic revision of the CAD state (runtime + document revision).
  int get stateRevision;

  Set<String> get selection;

  /// True when a document is open.
  bool get isReady;

  /// Read-only projection, always built from the authoritative state.
  Map<String, Object?> viewModel({
    required PanelId panelId,
    PanelProtocolLimits limits = const PanelProtocolLimits(),
  });

  void addListener(void Function() listener);

  void removeListener(void Function() listener);

  /// Applies a panel selection in the main session.
  Future<void> applySelection(Set<String> ids);

  /// True when the session exposes a safe, transactional visibility API.
  bool get supportsVisibility;

  /// Applies a document visibility change in the main session.
  Future<void> setEntityVisibility(String id, {required bool visible});
}

/// In-memory source used by the harness and by the protocol tests.
class FakePanelSessionSource implements PanelSessionSource {
  FakePanelSessionSource({
    this.projectId,
    this.sessionId = 1,
    List<({String id, String kind, String label, bool visible})> entities =
        const [],
    this.supportsVisibility = true,
    this.visibilityGate,
    this.selectionGate,
  }) : _entities = List.of(entities);

  @override
  String? projectId;

  @override
  int sessionId;

  @override
  bool supportsVisibility;

  /// Optional hook: lets a test make visibility application fail.
  final Future<void> Function(String id, bool visible)? visibilityGate;

  /// Optional hook: lets a test switch projects while an intent is in flight.
  final Future<void> Function(Set<String> ids)? selectionGate;

  /// Extra keys merged into the projection: test hook for oversized payloads.
  final Map<String, Object?> extraViewModel = {};

  final List<({String id, String kind, String label, bool visible})> _entities;
  final Set<String> _selection = {};
  final List<void Function()> _listeners = [];

  @override
  int stateRevision = 0;
  int selectionApplications = 0;
  int visibilityApplications = 0;
  final List<Set<String>> appliedSelections = [];
  final List<({String id, bool visible})> appliedVisibilities = [];

  @override
  Set<String> get selection => Set.unmodifiable(_selection);

  @override
  bool get isReady => projectId != null;

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  Map<String, Object?> viewModel({
    required PanelId panelId,
    PanelProtocolLimits limits = const PanelProtocolLimits(),
  }) => {
    PanelViewModelKeys.panelId: panelId.name,
    PanelViewModelKeys.projectId: projectId,
    PanelViewModelKeys.sessionId: sessionId,
    PanelViewModelKeys.stateRevision: stateRevision,
    PanelViewModelKeys.entities: [
      for (final entity in _entities.take(limits.maxViewModelEntities))
        {
          'id': entity.id,
          'label': entity.label,
          'kind': entity.kind,
          'visible': entity.visible,
        },
    ],
    PanelViewModelKeys.groups: {
      for (final kind
          in _entities.map((entity) => entity.kind).toSet().toList()..sort())
        kind: _entities.where((entity) => entity.kind == kind).length,
    },
    PanelViewModelKeys.selection: _selection.toList()..sort(),
    PanelViewModelKeys.status: 'ready',
    PanelViewModelKeys.empty: projectId == null,
    PanelViewModelKeys.truncated:
        _entities.length > limits.maxViewModelEntities,
    PanelViewModelKeys.entityCount: _entities.length,
    ...extraViewModel,
  };

  @override
  Future<void> applySelection(Set<String> ids) async {
    if (selectionGate != null) await selectionGate!(ids);
    selectionApplications++;
    appliedSelections.add(Set.unmodifiable(ids));
    _selection
      ..clear()
      ..addAll(ids.where((id) => _entities.any((e) => e.id == id)));
    _mutated();
  }

  @override
  Future<void> setEntityVisibility(String id, {required bool visible}) async {
    if (visibilityGate != null) await visibilityGate!(id, visible);
    visibilityApplications++;
    appliedVisibilities.add((id: id, visible: visible));
    final index = _entities.indexWhere((entity) => entity.id == id);
    if (index >= 0) {
      final current = _entities[index];
      _entities[index] = (
        id: current.id,
        kind: current.kind,
        label: current.label,
        visible: visible,
      );
    }
    _mutated();
  }

  /// Simulates a main-side change (selection made in the viewport, document
  /// updated, project opened/closed, session replaced).
  void setSelection(Iterable<String> ids) {
    _selection
      ..clear()
      ..addAll(ids);
    _mutated();
  }

  void addEntity({
    required String id,
    String kind = 'sketch',
    String? label,
    bool visible = true,
  }) {
    _entities.add((id: id, kind: kind, label: label ?? id, visible: visible));
    _mutated();
  }

  void openProject(String projectId) {
    this.projectId = projectId;
    _mutated();
  }

  void closeProject() {
    projectId = null;
    _selection.clear();
    _mutated();
  }

  void replaceSession(int sessionId, {String? projectId}) {
    this.sessionId = sessionId;
    this.projectId = projectId;
    _selection.clear();
    _mutated();
  }

  void _mutated() {
    stateRevision++;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

/// Real adapter over the single [CadRuntime] owned by the main process.
///
/// Read-only projections come from the document; the two mutations reuse the
/// existing safe APIs (`select` for the geometry selection and
/// `setEntityVisibility`, which runs inside the runtime's transaction).
class CadRuntimePanelSessionSource implements PanelSessionSource {
  CadRuntimePanelSessionSource(this.runtime);

  final CadRuntime runtime;

  @override
  String? get projectId => runtime.document?.projectId;

  @override
  int get sessionId => runtime.sessionIdentity;

  @override
  int get stateRevision =>
      runtime.runtimeRevision + (runtime.document?.revision ?? 0);

  @override
  Set<String> get selection => runtime.selection;

  @override
  bool get isReady => runtime.document != null;

  @override
  /// Audit finding (G124-UX.MM3): the only reuse candidate,
  /// `CadRuntime.setEntityVisibility`, is *display-only*: for the audited
  /// entity kinds (mesh import inside a system collection) it left both the
  /// document flag (`sceneVisible`) and the scene untouched, so exposing
  /// `visibility.set` here would promise something the main session cannot
  /// deliver. The action stays in the protocol whitelist and is re-enabled when
  /// a verified documental visibility API is wired (MM4).
  bool get supportsVisibility => false;

  @override
  Map<String, Object?> viewModel({
    required PanelId panelId,
    PanelProtocolLimits limits = const PanelProtocolLimits(),
  }) => PanelViewModel.build(
    panelId: panelId,
    sessionId: sessionId,
    projectId: projectId,
    stateRevision: stateRevision,
    document: runtime.document,
    selection: runtime.selection,
    status: runtime.document?.revision.toString() ?? '',
    limits: limits,
  );

  @override
  void addListener(void Function() listener) => runtime.addListener(listener);

  @override
  void removeListener(void Function() listener) =>
      runtime.removeListener(listener);

  @override
  Future<void> applySelection(Set<String> ids) async => runtime.select(ids);

  @override
  Future<void> setEntityVisibility(String id, {required bool visible}) =>
      runtime.setEntityVisibility(id, visible);
}

/// Re-exported so the bridge can build Explorer rows without importing the
/// document model itself.
typedef PanelDocument = CadDocument;
