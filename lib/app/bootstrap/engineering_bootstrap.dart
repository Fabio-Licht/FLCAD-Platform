import 'dart:io';

import '../../core/autonomous_reconstruction/api/autonomous_reconstruction_api.dart';
import '../../core/adaptive_studio/analytics/workspace_analytics.dart';
import '../../core/adaptive_studio/history/workspace_history.dart';
import '../../core/adaptive_studio/runtime/adaptive_studio_runtime.dart';
import '../../core/alignment_engine/analytics/alignment_analytics.dart';
import '../../core/alignment_engine/history/alignment_history.dart';
import '../../core/alignment_engine/runtime/alignment_runtime.dart';
import '../../core/cad_builder/integration/cad_builder_factory.dart';
import '../../core/cad_features/integration/feature_factory.dart';
import '../../core/cad_kernel/manager/kernel_manager.dart';
import '../../core/cad_kernel/opencascade/open_cascade_kernel_plugin.dart';
import '../../core/engineering/cache/engineering_cache.dart';
import '../../core/engineering/plugins/plugin_registry.dart';
import '../../core/engineering/serialization/schema_registry.dart';
import '../../core/engineering/services/engineering_service_registry.dart';
import '../../core/engineering_cognition/api/engineering_cognition_api.dart';
import '../../core/engineering_decision/api/decision_api.dart';
import '../../core/engineering_decision/engine/engineering_decision_engine.dart';
import '../../core/engineering_decision/memory/decision_memory.dart';
import '../../core/engineering_knowledge/api/engineering_knowledge_api.dart';
import '../../core/engineering_reconstruction/api/engineering_reconstruction_api.dart';
import '../../core/engineering_reconstruction/planner/engineering_reconstruction_planner.dart';
import '../../core/engineering_intelligence/analytics/intelligence_analytics.dart';
import '../../core/engineering_intelligence/history/intelligence_history.dart';
import '../../core/engineering_intelligence/runtime/intelligence_runtime.dart';
import '../../core/feature_modeling/analytics/feature_analytics.dart';
import '../../core/feature_modeling/history/feature_history.dart';
import '../../core/feature_modeling/integration/feature_modeling_factory.dart';
import '../../core/feature_modeling/repository/feature_repository.dart';
import '../../core/feature_modeling/runtime/feature_runtime.dart';
import '../../core/geometric_kernel/api/geometric_kernel_api.dart';
import '../../core/extrude_feature/integration/extrude_factory.dart';
import '../../core/extrude_feature/runtime/extrude_runtime.dart';
import '../../core/extrude_feature/repository/extrude_repository.dart';
import '../../core/extrude_feature/analytics/extrude_analytics.dart';
import '../../core/extrude_feature/history/extrude_history.dart';
import '../../core/geometric_recognition/api/recognition_api.dart';
import '../../core/geometric_recognition/engine/geometric_recognition_engine.dart';
import '../../core/hybrid_surface_engine/integration/hybrid_surface_factory.dart';
import '../../core/interactive_reverse/runtime/interactive_reverse_runtime.dart';
import '../../core/live_validation/analytics/validation_analytics.dart';
import '../../core/live_validation/history/validation_history.dart';
import '../../core/live_validation/history/validation_timeline.dart';
import '../../core/live_validation/runtime/live_validation_runtime.dart';
import '../../core/mesh_foundation/analytics/mesh_analytics.dart';
import '../../core/mesh_foundation/history/mesh_history.dart';
import '../../core/mesh_foundation/runtime/mesh_runtime.dart';
import '../../core/platform_certification/runtime/platform_certification_runtime.dart';
import '../../core/profile_recognition/analytics/profile_analytics.dart';
import '../../core/profile_recognition/history/profile_history.dart';
import '../../core/profile_recognition/integration/profile_factory.dart';
import '../../core/profile_recognition/repository/profile_repository.dart';
import '../../core/profile_recognition/runtime/profile_runtime.dart';
import '../../core/professional_recognition/api/professional_recognition_api.dart';
import '../../core/professional_recognition/engine/professional_recognition_engine.dart';
import '../../core/reference_geometry/analytics/reference_analytics.dart';
import '../../core/reference_geometry/history/reference_history.dart';
import '../../core/reference_geometry/repository/reference_repository.dart';
import '../../core/reference_geometry/runtime/reference_runtime.dart';
import '../../core/reverse_intelligence/api/reverse_intelligence_api.dart';
import '../../core/reverse_session/runtime/reverse_session_runtime.dart';
import '../../core/reverse_workflow/analytics/workflow_analytics.dart';
import '../../core/reverse_workflow/history/workflow_history.dart';
import '../../core/reverse_workflow/history/workflow_timeline.dart';
import '../../core/reverse_workflow/runtime/reverse_workflow_runtime.dart';
import '../../core/revolve_feature/analytics/revolve_analytics.dart';
import '../../core/revolve_feature/history/revolve_history.dart';
import '../../core/revolve_feature/runtime/revolve_runtime.dart';
import '../../core/sketch_constraints/analytics/constraint_analytics.dart';
import '../../core/sketch_constraints/history/constraint_history.dart';
import '../../core/sketch_constraints/integration/constraint_factory.dart';
import '../../core/sketch_constraints/repository/constraint_repository.dart';
import '../../core/sketch_constraints/runtime/constraint_runtime.dart';
import '../../core/sketch_editor/analytics/editor_analytics.dart';
import '../../core/sketch_editor/history/editor_history.dart';
import '../../core/sketch_editor/integration/editor_factory.dart';
import '../../core/sketch_editor/repository/editor_repository.dart';
import '../../core/sketch_editor/runtime/editor_runtime.dart';
import '../../core/sketch_engine/analytics/sketch_analytics.dart';
import '../../core/sketch_engine/history/sketch_history.dart';
import '../../core/sketch_engine/integration/sketch_factory.dart';
import '../../core/sketch_engine/repository/sketch_repository.dart';
import '../../core/sketch_engine/runtime/sketch_runtime.dart';
import '../../core/surface_generation/integration/surface_generation_factory.dart';
import '../../core/surface_intelligence/integration/surface_factory.dart';
import '../../core/transition_features/analytics/transition_analytics.dart';
import '../../core/transition_features/history/transition_history.dart';
import '../../core/transition_features/runtime/transition_runtime.dart';

/// Process-wide composition root for stateless engines and factories.
/// Project state belongs exclusively to the active CadRuntime/CadDocument.
class EngineeringBootstrap {
  EngineeringBootstrap._();
  static final instance = EngineeringBootstrap._();

  final cache = EngineeringCache();
  final schemas = SchemaRegistry();
  final plugins = EngineeringPluginRegistry();
  final services = EngineeringServiceRegistry();
  bool _initialized = false;

  void initialize() {
    if (_initialized) return;
    services
      ..register<EngineeringCache>(cache)
      ..register<SchemaRegistry>(schemas)
      ..register<EngineeringPluginRegistry>(plugins)
      ..register<GeometricKernelApi>(const GeometricKernelApi())
      ..register<ReverseIntelligenceApi>(ReverseIntelligenceApi())
      ..register<EngineeringKnowledgeApi>(EngineeringKnowledgeApi())
      ..register<EngineeringCognitionApi>(EngineeringCognitionApi())
      ..register<AutonomousReconstructionApi>(AutonomousReconstructionApi());
    services.register<DecisionApi>(
      DecisionApi(
        engine: EngineeringDecisionEngine(
          memory: DecisionMemory(ProjectDecisionMemoryStore()),
        ),
      ),
    );
    services.register<RecognitionApi>(
      RecognitionApi(
        engine: GeometricRecognitionEngine(
          decisions: services.get<DecisionApi>(),
        ),
      ),
    );
    services.register<ProfessionalRecognitionApi>(
      ProfessionalRecognitionApi(
        engine: ProfessionalRecognitionEngine(
          decisions: services.get<DecisionApi>(),
        ),
      ),
    );
    services.register<EngineeringReconstructionApi>(
      EngineeringReconstructionApi(
        planner: EngineeringReconstructionPlanner(
          decisions: services.get<DecisionApi>(),
        ),
      ),
    );
    final kernels = KernelManager();
    OpenCascadeKernelPlugin().register(kernels);
    services
      ..register<KernelManager>(kernels)
      ..register<CadBuilderFactory>(CadBuilderFactory(kernels))
      ..register<FeatureFactory>(FeatureFactory(kernels))
      ..register<ExtrudeFactory>(const ExtrudeFactory())
      ..register<ExtrudeRuntime>(ExtrudeRuntime())
      ..register<ExtrudeRepository>(ExtrudeRepository(Directory.systemTemp))
      ..register<ExtrudeAnalytics>(ExtrudeAnalytics())
      ..register<ExtrudeHistory>(ExtrudeHistory())
      ..register<AdaptiveStudioRuntime>(AdaptiveStudioRuntime())
      ..register<WorkspaceHistory>(WorkspaceHistory())
      ..register<WorkspaceAnalytics>(WorkspaceAnalytics())
      ..register<AlignmentRuntime>(AlignmentRuntime())
      ..register<AlignmentHistory>(AlignmentHistory())
      ..register<AlignmentAnalytics>(AlignmentAnalytics())
      ..register<EngineeringIntelligenceRuntime>(
        EngineeringIntelligenceRuntime(),
      )
      ..register<IntelligenceHistory>(IntelligenceHistory())
      ..register<IntelligenceAnalytics>(IntelligenceAnalytics())
      ..register<FeatureModelingFactory>(const FeatureModelingFactory())
      ..register<FeatureModelingRuntime>(FeatureModelingRuntime())
      ..register<FeatureRepository>(FeatureRepository(Directory.systemTemp))
      ..register<FeatureAnalytics>(FeatureAnalytics())
      ..register<FeatureHistory>(FeatureHistory())
      ..register<InteractiveReverseRuntime>(InteractiveReverseRuntime())
      ..register<LiveValidationRuntime>(LiveValidationRuntime())
      ..register<ValidationHistory>(ValidationHistory())
      ..register<ValidationTimeline>(ValidationTimeline())
      ..register<ValidationAnalytics>(ValidationAnalytics())
      ..register<MeshRuntime>(MeshRuntime())
      ..register<MeshAnalytics>(MeshAnalytics())
      ..register<MeshHistory>(MeshHistory())
      ..register<PlatformCertificationRuntime>(PlatformCertificationRuntime())
      ..register<ProfileRecognitionFactory>(const ProfileRecognitionFactory())
      ..register<ProfileRecognitionRuntime>(ProfileRecognitionRuntime())
      ..register<ProfileRepository>(ProfileRepository(Directory.systemTemp))
      ..register<ProfileAnalytics>(ProfileAnalytics())
      ..register<ProfileHistory>(ProfileHistory())
      ..register<ReferenceRuntime>(ReferenceRuntime())
      ..register<ReferenceHistory>(ReferenceHistory())
      ..register<ReferenceAnalytics>(ReferenceAnalytics())
      ..register<ReferenceRepository>(ReferenceRepository(Directory.systemTemp))
      ..register<ReverseSessionRuntime>(ReverseSessionRuntime())
      ..register<ReverseWorkflowRuntime>(ReverseWorkflowRuntime())
      ..register<WorkflowHistory>(WorkflowHistory())
      ..register<WorkflowTimeline>(WorkflowTimeline())
      ..register<WorkflowAnalytics>(WorkflowAnalytics())
      ..register<RevolveRuntime>(RevolveRuntime())
      ..register<RevolveHistory>(RevolveHistory())
      ..register<RevolveAnalytics>(RevolveAnalytics())
      ..register<ConstraintFactory>(const ConstraintFactory())
      ..register<ConstraintRuntime>(ConstraintRuntime())
      ..register<ConstraintRepository>(
        ConstraintRepository(Directory.systemTemp),
      )
      ..register<ConstraintAnalytics>(ConstraintAnalytics())
      ..register<ConstraintHistory>(ConstraintHistory())
      ..register<SketchEditorFactory>(const SketchEditorFactory())
      ..register<EditorRuntime>(EditorRuntime())
      ..register<EditorRepository>(EditorRepository(Directory.systemTemp))
      ..register<EditorAnalytics>(EditorAnalytics())
      ..register<EditorHistory>(EditorHistory())
      ..register<SketchRuntime>(SketchRuntime())
      ..register<SketchEngineFactory>(const SketchEngineFactory())
      ..register<SketchAnalytics>(SketchAnalytics())
      ..register<SketchHistory>(SketchHistory())
      ..register<SketchRepository>(SketchRepository(Directory.systemTemp))
      ..register<TransitionRuntime>(TransitionRuntime())
      ..register<TransitionHistory>(TransitionHistory())
      ..register<TransitionAnalytics>(TransitionAnalytics())
      ..register<SurfaceIntelligenceFactory>(const SurfaceIntelligenceFactory())
      ..register<SurfaceGenerationFactory>(SurfaceGenerationFactory(kernels))
      ..register<HybridSurfaceFactory>(const HybridSurfaceFactory());
    _initialized = true;
  }
}
