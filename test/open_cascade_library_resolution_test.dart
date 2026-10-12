import 'dart:io';

import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release resolves OpenCascade beside the executable', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('flcad-occ-path-');
    addTearDown(() => root.delete(recursive: true));
    final executable = File('${root.path}\\flcad_mobile.exe');
    final bundled = File('${root.path}\\flcad_opencascade.dll');
    await executable.writeAsString('runner');
    await bundled.writeAsString('native');

    expect(
      OpenCascadeFFI.resolveLibraryPath(executablePath: executable.path),
      bundled.path,
    );
  });

  test('an explicit OpenCascade path remains authoritative', () {
    const explicit = r'C:\custom\flcad_opencascade.dll';
    expect(
      OpenCascadeFFI.resolveLibraryPath(explicitPath: explicit),
      explicit,
    );
  });
}
