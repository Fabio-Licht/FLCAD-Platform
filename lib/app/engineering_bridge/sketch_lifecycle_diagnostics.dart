import 'package:flutter/foundation.dart';

/// Opt-in diagnostics for the isolated Sketch validation build.
/// Only lifecycle identifiers and stages are emitted; no geometry, paths or
/// document contents are recorded. Disabled unless explicitly enabled.
abstract final class SketchLifecycleDiagnostics {
  static const enabled = bool.fromEnvironment(
    'FLCAD_SKETCH_LIFECYCLE_DIAGNOSTICS',
    defaultValue: false,
  );

  static void record(String event, {String? entityId, String? stage}) {
    if (!enabled) return;
    final fields = <String>[
      if (entityId != null) 'entity=$entityId',
      if (stage != null) 'stage=$stage',
    ];
    debugPrint(
      '[sketch-lifecycle] $event${fields.isEmpty ? '' : ' ${fields.join(' ')}'}',
    );
  }
}
