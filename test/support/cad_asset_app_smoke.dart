// Explicit test entrypoint for the real Windows runner. Never imported by main.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/desktop/desktop_asset_manager.dart';
import 'package:flcad_mobile/app/desktop/desktop_settings.dart';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

class _Settings implements DesktopSettingsRepository {
  @override
  Future<DesktopSettings> load() async =>
      DesktopSettings(firstRunCompleted: false);
  @override
  Future<void> save(DesktopSettings settings) async =>
      throw StateError('Interactive changes disabled in smoke');
}

class _Trace extends CadAssetStorage {
  final phases = <String>[];
  @override
  Future<void> checkpoint(String phase) async {
    phases.add(phase);
  }
}

Map<String, Object> loadedHelper() {
  final kernel = ffi.DynamicLibrary.open('kernel32.dll');
  final getModule = kernel
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf16>),
        ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf16>)
      >('GetModuleHandleW');
  final getPath = kernel
      .lookupFunction<
        ffi.Uint32 Function(
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<Utf16>,
          ffi.Uint32,
        ),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<Utf16>, int)
      >('GetModuleFileNameW');
  final name = 'cad_asset_fs.dll'.toNativeUtf16();
  final buffer = calloc<ffi.Uint16>(32768);
  try {
    // Observe the module already loaded by staging, without preloading it.
    final module = getModule(name);
    require(module != ffi.nullptr, 'Gateway did not load cad_asset_fs.dll');
    final length = getPath(module, buffer.cast(), 32768);
    require(length > 0 && length < 32768, 'Cannot identify loaded helper');
    final actual = String.fromCharCodes(buffer.asTypedList(length));
    final expected = p.join(
      p.dirname(Platform.resolvedExecutable),
      'cad_asset_fs.dll',
    );
    require(
      p.equals(actual.toLowerCase(), expected.toLowerCase()),
      'Helper was not loaded from the app bundle',
    );
    final dll = ffi.DynamicLibrary.open(actual);
    final abi = dll.lookupFunction<ffi.Uint32 Function(), int Function()>(
      'caf_abi_version',
    )();
    final gateway = dll.lookupFunction<ffi.Uint32 Function(), int Function()>(
      'caf_gateway_version',
    )();
    require(abi == 1 && gateway == 1, 'ABI negotiation failed');
    return {'path': actual, 'abi': abi, 'gateway': gateway};
  } finally {
    calloc.free(name);
    calloc.free(buffer);
  }
}

bool wizardMounted() {
  var found = false;
  void visit(Element element) {
    if (element.widget is FirstRunWizard) found = true;
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  require(Platform.isWindows, 'Windows smoke only');
  require(
    !Platform.environment.containsKey('FLCAD_CAD_ASSET_FS_DLL'),
    'Smoke forbids helper override',
  );
  final rootPath = Platform.environment['FLCAD_CAD_SMOKE_ROOT'];
  require(
    rootPath != null && p.isAbsolute(rootPath),
    'Exclusive smoke root required',
  );
  final root = Directory(rootPath!);
  require(await root.exists(), 'Harness must create exclusive root');
  final reportFile = File(p.join(root.path, 'smoke-result.json'));
  require(!await reportFile.exists(), 'Refusing to replace report');
  final report = <String, Object?>{
    'pid': pid,
    'executable': Platform.resolvedExecutable,
    'started': DateTime.now().toUtc().toIso8601String(),
  };
  final trace = _Trace();
  final runtime = CadRuntime(kernels: KernelManager(), assetStorage: trace);
  final uiErrors = <String>[];
  FlutterError.onError = (details) {
    uiErrors.add(details.exceptionAsString());
  };
  try {
    runApp(
      FLCADDesktopApplication(
        settingsRepository: _Settings(),
        splashStep: const Duration(milliseconds: 10),
        platformInitializer: () => DesktopAssetManager(rootBundle).validate(),
        colmapLabRuntimeFactory: () async => throw StateError(
          'COLMAP intentionally disabled for filesystem smoke',
        ),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!wizardMounted() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    require(
      wizardMounted(),
      'Desktop application did not reach test configuration',
    );
    await WidgetsBinding.instance.endOfFrame;
    report['desktopFrame'] = 'FirstRunWizard';
    final project = Directory(p.join(root.path, 'discardable-project'));
    require(!await project.exists(), 'Project must be new');
    await project.create();
    await runtime.open('filesystem-smoke', project);
    final payload = List<int>.generate(131079, (i) => i % 251);
    late String stage;
    final assets = await runtime.withGeometryStaging((operation) async {
      stage = operation.stagingDirectory;
      final id = await operation.planAsset();
      await operation.write(id, CadAssetFile.source, Stream.value(payload));
      await operation.prepare();
      report['helper'] = loadedHelper();
      return operation.promote();
    });
    require(!assets.documentPublished, 'Smoke must not publish geometry');
    final recovered = await inspectCadAssetStaging(project);
    require(
      recovered.length == 1 &&
          recovered.single.assetsVerified &&
          recovered.single.classification == 'awaitingDocumentReconciliation',
      'Native recovery/readback failed',
    );
    final manifest =
        (jsonDecode(await File(p.join(stage, 'manifest.json')).readAsString())
                as Map)['data']
            as Map;
    require(manifest['state'] == 'committed', 'Journal did not confirm commit');
    final metadata =
        ((manifest['assets'] as List).single as Map)['files'] as Map;
    report['payload'] = metadata['source'];
    report['asset'] = assets.assets.single.value;
    report['project'] = project.path;
    report['phases'] = trace.phases;
    require(
      trace.phases.contains('file:flushed') &&
          trace.phases.contains('promotion:renamed') &&
          trace.phases.contains('manifest:committed:replaced'),
      'Missing real staging milestones',
    );
    await runtime.shutdown();
    await runtime.shutdown();
    // Every live helper capability pins the project without SHARE_DELETE.
    // Successful rename after shutdown proves that no such project handle remains.
    final closed = await project.rename('${project.path}.closed-probe');
    await closed.rename(project.path);
    report['shutdown'] =
        'drained; repeated shutdown completed; exclusive project rename succeeded';
    require(uiErrors.isEmpty, 'Desktop errors: $uiErrors');
    report['status'] = 'PASS';
  } catch (error, stack) {
    report['status'] = 'FAIL';
    report['error'] = '$error';
    report['stack'] = '$stack';
    await runtime.shutdown();
  } finally {
    report['finished'] = DateTime.now().toUtc().toIso8601String();
    await reportFile.create(exclusive: true);
    await reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    // The external harness sends WM_CLOSE to this process's real runner window
    // after consuming the flushed report, then checks the process exit code.
    await File(p.join(root.path, 'smoke-complete')).create(exclusive: true);
  }
}
