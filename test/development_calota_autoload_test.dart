import 'dart:async';

import 'package:flcad_mobile/app/desktop/development_calota_autoload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'commercial isolate reads compile-time fromEnvironment, not a path in app.so',
    () {
      expect(
        DevelopmentCalotaAutoloadPolicy.compileTimeEnabled,
        isFalse,
        reason:
            'flutter test is not built with --dart-define=FLCAD_DEV_AUTOLOAD_CALOTA=true',
      );
      expect(DevelopmentCalotaAutoloadPolicy.compileTimePath, isEmpty);
      final commercial = DevelopmentCalotaAutoloadPolicy.resolve(
        debugMode: false,
        debugEnvironment: const {
          'FLCAD_DEV_AUTOLOAD_CALOTA': 'true',
          'FLCAD_DEV_STL_PATH': r'C:\TRABALHO\MAHA 3D\CALOTA_INOXX\CALOTA_INOXX.stl',
        },
      );
      expect(commercial.enabled, isFalse);
      expect(commercial.path, isEmpty);
      expect(commercial.source, DevelopmentCalotaAutoloadSource.off);
    },
  );

  test(
    'debug isolate may read FLCAD_DEV_* from the process environment',
    () {
      final policy = DevelopmentCalotaAutoloadPolicy.resolve(
        debugMode: true,
        debugEnvironment: const {
          'FLCAD_DEV_AUTOLOAD_CALOTA': 'true',
          'FLCAD_DEV_STL_PATH': r'C:\dev\calota.stl',
        },
      );
      expect(policy.enabled, isTrue);
      expect(policy.path, r'C:\dev\calota.stl');
      expect(policy.source, DevelopmentCalotaAutoloadSource.debugEnvironment);
    },
  );

  test(
    'legacy autoload after commands.initialize fired before document/viewport ready',
    () {
      expect(
        developmentCalotaLegacyWouldImportAfterCommandsInitialize(
          commandsReady: true,
          documentOpen: false,
          viewportReady: false,
        ),
        isTrue,
        reason:
            'DesktopShell used to dispatch import.stl as soon as commands.initialize() completed',
      );
      expect(
        developmentCalotaCanStart(
          enabled: true,
          commandsReady: true,
          documentOpen: false,
          runtimeReady: false,
          viewportReady: false,
          alreadyConsumed: false,
        ),
        isFalse,
      );
      expect(
        developmentCalotaCanStart(
          enabled: true,
          commandsReady: true,
          documentOpen: true,
          runtimeReady: true,
          viewportReady: true,
          alreadyConsumed: false,
        ),
        isTrue,
      );
    },
  );

  test(
    'autoload waits for late readiness, imports once, fits only after mesh publish',
    () async {
      final ready = Completer<void>();
      var ensureCalls = 0;
      var importCalls = 0;
      var fitCalls = 0;
      final events = <String>[];
      final runner = DevelopmentCalotaAutoload();
      final pending = runner.run(
        policy: const DevelopmentCalotaAutoloadPolicy(
          enabled: true,
          path: r'C:\dev\calota.stl',
          source: DevelopmentCalotaAutoloadSource.debugEnvironment,
        ),
        waitUntilReady: () => ready.future,
        fileExists: (path) async {
          expect(path, r'C:\dev\calota.stl');
          return true;
        },
        ensureProject: () async {
          ensureCalls++;
        },
        alreadyContainsCalota: (_) async => false,
        importStl: (path) async {
          importCalls++;
          expect(ready.isCompleted, isTrue);
          expect(path, r'C:\dev\calota.stl');
          return const DevelopmentCalotaImportOutcome(
            entityId: 'stl-calota',
            meshPublished: true,
            visible: true,
          );
        },
        fitViewAfterMeshPublished: () async {
          expect(importCalls, 1);
          fitCalls++;
        },
        log: (event, _) => events.add(event),
      );

      await Future<void>.delayed(Duration.zero);
      expect(importCalls, 0);
      expect(ensureCalls, 0);
      expect(fitCalls, 0);

      ready.complete();
      final report = await pending;
      expect(report.attempted, isTrue);
      expect(report.imported, isTrue);
      expect(report.fitted, isTrue);
      expect(report.entityId, 'stl-calota');
      expect(importCalls, 1);
      expect(ensureCalls, 1);
      expect(fitCalls, 1);
      expect(events, containsAllInOrder(['start', 'command', 'scene.publish', 'fit-view']));
      expect(report.fitted, isTrue);
      expect(
        events.where(
          (event) => event.contains('section') || event.contains('sketch'),
        ),
        isEmpty,
        reason:
            'CALOTA autoload must not create Section or Sketch automatically',
      );

      final second = await runner.run(
        policy: const DevelopmentCalotaAutoloadPolicy(
          enabled: true,
          path: r'C:\dev\calota.stl',
          source: DevelopmentCalotaAutoloadSource.debugEnvironment,
        ),
        waitUntilReady: () async {},
        fileExists: (_) async => true,
        ensureProject: () async {
          ensureCalls++;
        },
        alreadyContainsCalota: (_) async => false,
        importStl: (_) async {
          importCalls++;
          return const DevelopmentCalotaImportOutcome(
            entityId: 'stl-calota-2',
            meshPublished: true,
          );
        },
        fitViewAfterMeshPublished: () async {
          fitCalls++;
        },
      );
      expect(second.attempted, isFalse);
      expect(importCalls, 1);
      expect(fitCalls, 1);
    },
  );

  test('missing file and import errors stay non-blocking', () async {
    final missing = await DevelopmentCalotaAutoload().run(
      policy: const DevelopmentCalotaAutoloadPolicy(
        enabled: true,
        path: r'C:\missing\calota.stl',
        source: DevelopmentCalotaAutoloadSource.debugEnvironment,
      ),
      waitUntilReady: () async {},
      fileExists: (_) async => false,
      ensureProject: () async {},
      alreadyContainsCalota: (_) async => false,
      importStl: (_) async => throw StateError('should not import'),
      fitViewAfterMeshPublished: () async {},
    );
    expect(missing.attempted, isFalse);
    expect(missing.imported, isFalse);
    expect(missing.warning, contains('não encontrada'));

    final failed = await DevelopmentCalotaAutoload().run(
      policy: const DevelopmentCalotaAutoloadPolicy(
        enabled: true,
        path: r'C:\dev\calota.stl',
        source: DevelopmentCalotaAutoloadSource.debugEnvironment,
      ),
      waitUntilReady: () async {},
      fileExists: (_) async => true,
      ensureProject: () async {},
      alreadyContainsCalota: (_) async => false,
      importStl: (_) async => throw StateError('kernel refused'),
      fitViewAfterMeshPublished: () async {},
    );
    expect(failed.attempted, isTrue);
    expect(failed.imported, isFalse);
    expect(failed.fitted, isFalse);
    expect(failed.warning, contains('kernel refused'));
  });

  test('kDebugMode in this isolate is $kDebugMode and commercial stays off', () {
    expect(
      DevelopmentCalotaAutoloadPolicy.resolve(debugMode: false).enabled,
      isFalse,
    );
  });

  test('existing open geometry is not clobbered by autoload import', () async {
    var importCalls = 0;
    final report = await DevelopmentCalotaAutoload().run(
      policy: const DevelopmentCalotaAutoloadPolicy(
        enabled: true,
        path: r'C:\dev\calota.stl',
        source: DevelopmentCalotaAutoloadSource.debugEnvironment,
      ),
      waitUntilReady: () async {},
      fileExists: (_) async => true,
      ensureProject: () async {},
      alreadyContainsCalota: (_) async => false,
      hasExistingGeometry: () async => true,
      importStl: (_) async {
        importCalls++;
        return const DevelopmentCalotaImportOutcome(
          entityId: 'should-not-import',
          meshPublished: true,
        );
      },
      fitViewAfterMeshPublished: () async {},
    );
    expect(report.attempted, isFalse);
    expect(report.imported, isFalse);
    expect(report.warning, contains('não sobrescrever'));
    expect(importCalls, 0);
  });

  test('resolve never reads Platform.environment unless the caller passes it', () {
    expect(
      DevelopmentCalotaAutoloadPolicy.resolve().enabled,
      isFalse,
    );
    expect(
      DevelopmentCalotaAutoloadPolicy.resolve(debugMode: true).enabled,
      isFalse,
      reason: 'debugMode alone is not enough; env map must be explicit',
    );
    expect(
      DevelopmentCalotaAutoloadPolicy.resolve(debugMode: false).source,
      DevelopmentCalotaAutoloadSource.off,
    );
  });
}
