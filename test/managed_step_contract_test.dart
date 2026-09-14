import 'dart:convert';
import 'package:flcad_mobile/app/runtime/cad_runtime.dart';
import 'package:flcad_mobile/core/cad_document/cad_document.dart';
import 'package:flcad_mobile/core/cad_document/managed_step_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GeometryAssetId id(String digit) => GeometryAssetId.fromJson({
    'schema': 'flcad.geometry-asset',
    'version': 1,
    'id': 'ga1_${digit * 32}',
  });
  final hash = 'a' * 64;
  ManagedStepAssets refs() => ManagedStepAssets(
    shape: id('1'),
    display: id('2'),
    appearance: id('3'),
    shapeSha256: hash,
    displaySha256: hash,
    appearanceSha256: hash,
  );
  StepAppearanceManifest appearance() => StepAppearanceManifest(
    name: 'Peça única',
    declaredUnit: 'metre',
    declaredMetersPerUnit: 1,
    resolvedMetersPerUnit: .001,
    linearRgb: [.125, .5, .75],
  );
  Map<String, dynamic> entity() => {
    'id': 'part',
    'kind': 'import',
    'shape': null,
    'mesh': null,
    'data': {
      'name': 'Peça única',
      'format': 'step',
      'sceneKind': 'mesh',
      'managedStepAssets': refs().toJson(),
    },
  };

  test('STEP contract uses independent strict durable references', () {
    expect(
      ManagedStepAssets.fromJson(refs().toJson()).toJson(),
      refs().toJson(),
    );
    expect(CadDocumentEntity.fromJson(entity()).toJson(), entity());
    for (final change in [
      {'version': 2},
      {'meshOnly': true},
      {'sourceFormat': 'brep'},
      {'version': 1.0},
      {'appearanceManifestSha256': 'BAD'},
      {'pointer': 12},
      {'shapeAssetId': refs().display.toJson()},
      {'appearanceManifestAssetId': null},
    ]) {
      expect(
        () => ManagedStepAssets.fromJson({...refs().toJson(), ...change}),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      () => ManagedStepAssets(
        shape: id('1'),
        display: id('1'),
        appearance: id('3'),
        shapeSha256: hash,
        displaySha256: hash,
        appearanceSha256: hash,
      ),
      throwsA(isA<FormatException>()),
    );
  });
  test('STEP cannot combine transient or other managed document contracts', () {
    final brep = ManagedBrepAssets(
      shape: id('1'),
      display: id('2'),
      shapeSha256: hash,
      displaySha256: hash,
    );
    final stl = ManagedStlAssets(display: id('2'), displaySha256: hash);
    for (final extra in [
      {'managedBrepAssets': brep.toJson()},
      {'managedStlAssets': stl.toJson()},
      {'sourcePath': 'part.step'},
      {
        'residence': {'token': 'native'},
      },
      {
        'displayMeshDescriptor': {'fingerprint': 'resident'},
      },
      {
        'sceneGeometry': {'nodes': []},
      },
      {
        'featureLifecycle': {
          'nested': {'token': 'native'},
        },
      },
    ]) {
      final value = entity();
      (value['data'] as Map).addAll(extra);
      expect(
        () => CadDocumentEntity.fromJson(value),
        throwsA(isA<FormatException>()),
      );
    }
    for (final value in [brep.toJson(), stl.toJson()]) {
      final key = value['meshOnly'] == true
          ? 'managedStlAssets'
          : 'managedBrepAssets';
      final data = {
        'name': 'direct',
        'format': value['meshOnly'] == true ? 'stl' : 'brep',
        'sceneKind': 'mesh',
        key: value,
      };
      expect(
        CadDocumentEntity.fromJson({
          'id': 'direct',
          'kind': 'import',
          'data': data,
        }).data,
        data,
      );
      expect(
        () => CadDocumentEntity.fromJson({
          'id': 'direct',
          'kind': 'import',
          'data': {...data, 'appearanceManifest': appearance().toJson()},
        }),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      CadDocumentEntity.fromJson({
        'id': 'legacy',
        'kind': 'vertex',
        'data': {},
      }).id,
      'legacy',
    );
  });
  test('appearance has deterministic UTF8 encoding and explicit absence', () {
    final original = appearance();
    final reversed = Map<String, dynamic>.fromEntries(
      original.toJson().entries.toList().reversed,
    );
    expect(
      StepAppearanceManifest.fromJson(reversed).encode(),
      original.encode(),
    );
    expect(utf8.decode(original.encode()), contains('Peça única'));
    final absent = StepAppearanceManifest(
      name: '',
      declaredUnit: 'millimetre',
      declaredMetersPerUnit: .001,
      resolvedMetersPerUnit: .001,
      linearRgb: null,
    );
    expect(absent.hasColor, isFalse);
    expect(absent.toJson()['rootRgb'], isNull);
    for (final change in [
      {'hasColor': false},
      {'hasColor': true, 'rootRgb': null},
      {'alpha': .5},
      {
        'rootRgb': [double.nan, 0, 0],
      },
      {
        'rootRgb': [-1, 0, 0],
      },
      {'colorSpace': 'srgb'},
      {'declaredMetersPerUnit': 0},
      {'resolvedMetersPerUnit': 1},
      {'pathname': 'part.step'},
      {'version': 2},
      {'name': 'bad\u0000name'},
    ]) {
      expect(
        () =>
            StepAppearanceManifest.fromJson({...original.toJson(), ...change}),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
