import 'dart:io';

import 'package:flcad_mobile/core/cad_kernel/models/kernel_models.dart';
import 'package:flcad_mobile/core/cad_kernel/io/kernel_io_models.dart';
import 'package:flcad_mobile/core/cad_kernel/opencascade/open_cascade_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dll =
      Platform.environment['FLCAD_SOURCE_OCC_DLL'] ??
      r'C:\flcad_mobile\build\windows\x64\runner\Debug\flcad_opencascade.dll';
  final available = File(dll).existsSync();

  test(
    'OCCT planar recognition domain is a valid BRep face and survives STEP',
    () async {
      final ffi = OpenCascadeFFI.load(path: dll);
      await ffi.initialize();
      final face = await ffi.createShape('GENERATE PLANE', const {
        'origin': [0.0, 0.0, 0.0],
        'normal': [0.0, 0.0, 1.0],
        'lowerBound': -1.0,
        'upperBound': 1.0,
      }, CADShapeType.face);
      final step = '${Directory.systemTemp.path}\\flcad_er_p2d_c3.step';
      try {
        final topology = await ffi.inspectSurfaceTopology(face.token);
        expect(topology['area'], closeTo(4.0, 1e-6));
        expect(topology['perimeter'], closeTo(8.0, 1e-6));
        expect(topology['faceCount'], 1);
        expect(topology['edgeCount'], 4);
        expect(topology['vertexCount'], 4);
        expect(topology['valid'], isTrue);
        expect(
          (await ffi.validate(
            face.token,
          )).where((item) => item.severity.toLowerCase() == 'error'),
          isEmpty,
        );

        await ffi.exportShape(
          face.token,
          step,
          KernelExchangeFormat.step,
          cancellation: const NoKernelCancellation(),
        );
        final imported = await ffi.importShape(
          step,
          KernelExchangeFormat.step,
          cancellation: const NoKernelCancellation(),
        );
        try {
          expect(
            imported.type,
            anyOf(CADShapeType.face, CADShapeType.compound, CADShapeType.shell),
          );
          expect(
            (await ffi.validate(
              imported.token,
            )).where((item) => item.severity.toLowerCase() == 'error'),
            isEmpty,
          );
          if (imported.type == CADShapeType.face) {
            final importedTopology = await ffi.inspectSurfaceTopology(
              imported.token,
            );
            expect(importedTopology['faceCount'], 1);
            expect(importedTopology['edgeCount'], 4);
            expect(importedTopology['vertexCount'], 4);
            expect(importedTopology['valid'], isTrue);
          }
        } finally {
          await ffi.destroyShape(imported.token);
        }
      } finally {
        await ffi.destroyShape(face.token);
        await ffi.shutdown();
        final file = File(step);
        if (file.existsSync()) await file.delete();
      }
    },
    skip: available ? false : 'OCCT test DLL not available',
  );
}
