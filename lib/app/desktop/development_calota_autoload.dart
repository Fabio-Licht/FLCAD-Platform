import 'package:flutter/foundation.dart';

/// Compile-time dart-defines. These are NOT `Platform.environment` reads.
///
/// Development Release needs BOTH:
/// `--dart-define=FLCAD_DEV_AUTOLOAD_CALOTA=true` and
/// `--dart-define=FLCAD_DEV_STL_PATH=<absolute.stl>`.
/// Commercial Release keeps the defaults (`false` / empty) and never autoloads.
/// A path literal in `app.so` is not proof that autoload ran.
const bool kFlcadDevAutoloadCalota = bool.fromEnvironment(
  'FLCAD_DEV_AUTOLOAD_CALOTA',
  defaultValue: false,
);
const String kFlcadDevStlPath = String.fromEnvironment(
  'FLCAD_DEV_STL_PATH',
  defaultValue: '',
);

/// How the isolate obtained the autoload switch and path.
enum DevelopmentCalotaAutoloadSource {
  /// `--dart-define` baked into this isolate.
  compileTime,

  /// `FLCAD_DEV_*` process environment, only consulted in [kDebugMode].
  debugEnvironment,

  /// Commercial / default: both defines off, no debug fallback.
  off,
}

@immutable
class DevelopmentCalotaAutoloadPolicy {
  const DevelopmentCalotaAutoloadPolicy({
    required this.enabled,
    required this.path,
    required this.source,
  });

  final bool enabled;
  final String path;
  final DevelopmentCalotaAutoloadSource source;

  static const bool compileTimeEnabled = kFlcadDevAutoloadCalota;
  static const String compileTimePath = kFlcadDevStlPath;

  /// Resolves what this isolate actually reads.
  ///
  /// [fromEnvironment] is compile-time. Runtime `FLCAD_DEV_*` is never
  /// read implicitly from `Platform.environment` — the caller must pass
  /// [debugEnvironment] (DesktopShell does that only in [kDebugMode] and
  /// never under `FLUTTER_TEST`). Commercial Release stays off.
  static DevelopmentCalotaAutoloadPolicy resolve({
    Map<String, String>? debugEnvironment,
    bool? debugMode,
  }) {
    final debug = debugMode ?? kDebugMode;
    if (compileTimeEnabled) {
      return DevelopmentCalotaAutoloadPolicy(
        enabled: true,
        path: compileTimePath.trim(),
        source: DevelopmentCalotaAutoloadSource.compileTime,
      );
    }
    if (debug) {
      final env = debugEnvironment ?? const <String, String>{};
      final enabled =
          env['FLCAD_DEV_AUTOLOAD_CALOTA'] == 'true' ||
          env['FLCAD_DEV_AUTOLOAD_CALOTA'] == '1';
      final path = (env['FLCAD_DEV_STL_PATH'] ?? '').trim();
      if (enabled) {
        return DevelopmentCalotaAutoloadPolicy(
          enabled: true,
          path: path,
          source: DevelopmentCalotaAutoloadSource.debugEnvironment,
        );
      }
    }
    return const DevelopmentCalotaAutoloadPolicy(
      enabled: false,
      path: '',
      source: DevelopmentCalotaAutoloadSource.off,
    );
  }
}

/// Historical DesktopShell contract: dispatch `import.stl` as soon as
/// `commands.initialize()` finished. That ignored document/runtime/viewport
/// readiness — OfficialEngineeringWorkspace is not even mounted while the
/// shell stays on Home (`destination == 0`).
bool developmentCalotaLegacyWouldImportAfterCommandsInitialize({
  required bool commandsReady,
  required bool documentOpen,
  required bool viewportReady,
}) => commandsReady;

/// Real readiness gate: document open, runtime ready, first viewport frame.
bool developmentCalotaCanStart({
  required bool enabled,
  required bool commandsReady,
  required bool documentOpen,
  required bool runtimeReady,
  required bool viewportReady,
  required bool alreadyConsumed,
}) =>
    enabled &&
    commandsReady &&
    documentOpen &&
    runtimeReady &&
    viewportReady &&
    !alreadyConsumed;

@immutable
class DevelopmentCalotaImportOutcome {
  const DevelopmentCalotaImportOutcome({
    this.entityId,
    this.meshPublished = false,
    this.visible = false,
  });

  final String? entityId;
  final bool meshPublished;
  final bool visible;
}

@immutable
class DevelopmentCalotaAutoloadReport {
  const DevelopmentCalotaAutoloadReport({
    required this.attempted,
    required this.imported,
    required this.fitted,
    this.entityId,
    this.warning,
  });

  final bool attempted;
  final bool imported;
  final bool fitted;
  final String? entityId;
  final String? warning;
}

/// One-shot development STL autoload. Fit View is invoked only after the
/// import reports the mesh in the scene.
class DevelopmentCalotaAutoload {
  bool _consumed = false;
  bool get consumed => _consumed;

  Future<DevelopmentCalotaAutoloadReport> run({
    required DevelopmentCalotaAutoloadPolicy policy,
    required Future<void> Function() waitUntilReady,
    required Future<bool> Function(String path) fileExists,
    required Future<void> Function() ensureProject,
    required Future<bool> Function(String path) alreadyContainsCalota,
    Future<bool> Function()? hasExistingGeometry,
    required Future<DevelopmentCalotaImportOutcome> Function(String path)
    importStl,
    required Future<void> Function() fitViewAfterMeshPublished,
    void Function(String message)? reportStatus,
    void Function(String event, Map<String, Object?> fields)? log,
  }) async {
    void emit(String event, [Map<String, Object?> fields = const {}]) {
      if (kDebugMode || policy.enabled) {
        log?.call(event, fields);
      }
    }

    emit('start', {
      'enabled': policy.enabled,
      'source': policy.source.name,
      'path': policy.path,
      'compileTimeEnabled': DevelopmentCalotaAutoloadPolicy.compileTimeEnabled,
      'compileTimePath': DevelopmentCalotaAutoloadPolicy.compileTimePath,
    });
    if (!policy.enabled || _consumed) {
      emit('skip', {'reason': _consumed ? 'consumed' : 'disabled'});
      return const DevelopmentCalotaAutoloadReport(
        attempted: false,
        imported: false,
        fitted: false,
      );
    }
    _consumed = true;
    final locator = policy.path.trim();
    if (locator.isEmpty) {
      const warning =
          'Autoload CALOTA desabilitado: defina FLCAD_DEV_STL_PATH para o Release de desenvolvimento.';
      reportStatus?.call(warning);
      emit('empty-path', {'warning': warning});
      return const DevelopmentCalotaAutoloadReport(
        attempted: false,
        imported: false,
        fitted: false,
        warning:
            'Autoload CALOTA desabilitado: defina FLCAD_DEV_STL_PATH para o Release de desenvolvimento.',
      );
    }
    emit('path', {'path': locator});
    final exists = await fileExists(locator);
    emit('file.exists', {'path': locator, 'exists': exists});
    if (!exists) {
      final warning =
          'Aviso: CALOTA de desenvolvimento não encontrada em $locator. A inicialização continua normalmente.';
      reportStatus?.call(warning);
      return DevelopmentCalotaAutoloadReport(
        attempted: false,
        imported: false,
        fitted: false,
        warning: warning,
      );
    }
    try {
      emit('wait-ready', const {});
      await waitUntilReady();
      await ensureProject();
      if (await alreadyContainsCalota(locator)) {
        const warning = 'CALOTA de desenvolvimento já está carregada.';
        reportStatus?.call(warning);
        emit('already-loaded', {'path': locator});
        return const DevelopmentCalotaAutoloadReport(
          attempted: false,
          imported: false,
          fitted: false,
          warning: warning,
        );
      }
      if (await (hasExistingGeometry?.call() ?? Future.value(false))) {
        const warning =
            'Projeto existente com geometria: autoload CALOTA ignorado para não sobrescrever o documento.';
        reportStatus?.call(warning);
        emit('existing-geometry', {'path': locator});
        return const DevelopmentCalotaAutoloadReport(
          attempted: false,
          imported: false,
          fitted: false,
          warning: warning,
        );
      }
      emit('command', {'id': 'import.stl', 'path': locator});
      final outcome = await importStl(locator);
      emit('result', {
        'entityId': outcome.entityId,
        'meshPublished': outcome.meshPublished,
        'visible': outcome.visible,
      });
      var fitted = false;
      if (outcome.meshPublished) {
        emit('scene.publish', {'entityId': outcome.entityId});
        await fitViewAfterMeshPublished();
        fitted = true;
        emit('fit-view', {'entityId': outcome.entityId});
      }
      return DevelopmentCalotaAutoloadReport(
        attempted: true,
        imported: true,
        fitted: fitted,
        entityId: outcome.entityId,
      );
    } catch (error) {
      final warning =
          'Aviso: não foi possível carregar a CALOTA de desenvolvimento ($error). A inicialização continua normalmente.';
      reportStatus?.call(warning);
      emit('error', {'error': '$error'});
      return DevelopmentCalotaAutoloadReport(
        attempted: true,
        imported: false,
        fitted: false,
        warning: warning,
      );
    }
  }
}
