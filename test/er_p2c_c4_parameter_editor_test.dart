import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/core/geometric_kernel/geometry/vectors.dart';
import 'package:flcad_mobile/core/recognition_engine/recognition_parameter_editor.dart';

MeasuredGeometry _measured({
  double diameter = 17.964,
  List<Vector3>? points,
  String selection = 'selection-a',
}) => MeasuredGeometry(
  type: 'cylinder',
  meshId: 'mesh-a',
  regionId: 'region-a',
  meshFingerprint: 'mesh-fingerprint-a',
  selectionFingerprint: selection,
  selectionRevision: 1,
  parameters: {
    'diameter': diameter,
    'radius': diameter / 2,
    'origin': [0.0, 0.0, 0.0],
    'axis': [0.0, 0.0, 1.0],
  },
  points:
      points ??
      const [
        Vector3(8.982, 0, 0),
        Vector3(0, 8.982, 0),
        Vector3(-8.982, 0, 10),
        Vector3(0, -8.982, 10),
      ],
);

RecognitionParameterEditor _editor({
  double diameter = 17.964,
  List<Vector3>? points,
}) {
  final measured = _measured(diameter: diameter, points: points);
  return RecognitionParameterEditor(
    measured: measured,
    target: TargetGeometry(
      diameter: diameter,
      origin: Vector3.zero,
      axis: const Vector3(0, 0, 1),
      axisSource: 'recognized',
      anchor: 'recognized-center',
    ),
  );
}

void main() {
  test('ER-P2C-C4 diameter 17.964 can be corrected to 18.000', () {
    final editor = _editor();
    editor.setDiameter(18.000);
    expect(editor.target.diameter, 18.000);
    expect(editor.target.diameter / 2, 9.000);
    expect(editor.proposal.valid, isTrue);
  });

  test('radius updates the equivalent diameter', () {
    final editor = _editor();
    editor.setRadius(9.0);
    expect(editor.target.diameter, 18.0);
  });

  test('global X, Y and Z frames provide real unit directions', () {
    const frame = RecognitionCoordinateFrame(
      id: 'global',
      label: 'Global',
      kind: RecognitionFrameKind.global,
      origin: Vector3.zero,
      xAxis: Vector3(1, 0, 0),
      yAxis: Vector3(0, 1, 0),
      zAxis: Vector3(0, 0, 1),
    );
    expect(frame.direction('X').toJson(), [1.0, 0.0, 0.0]);
    expect(frame.direction('Y').toJson(), [0.0, 1.0, 0.0]);
    expect(frame.direction('Z').toJson(), [0.0, 0.0, 1.0]);
  });

  test('WCS directions are consumed from the selected frame', () {
    const frame = RecognitionCoordinateFrame(
      id: 'wcs:test',
      label: 'WCS Teste',
      kind: RecognitionFrameKind.wcs,
      origin: Vector3(10, 20, 30),
      xAxis: Vector3(0, 1, 0),
      yAxis: Vector3(-1, 0, 0),
      zAxis: Vector3(0, 0, 1),
    );
    final editor = _editor();
    editor.setAxis(frame.direction('X'), source: 'wcs:test:X');
    expect(editor.target.axis.toJson(), [0.0, 1.0, 0.0]);
    expect(editor.target.origin.toJson(), [0.0, 0.0, 0.0]);
  });

  test('no WCS is represented by the global frame only', () {
    const frames = <RecognitionCoordinateFrame>[
      RecognitionCoordinateFrame(
        id: 'global',
        label: 'Global',
        kind: RecognitionFrameKind.global,
        origin: Vector3.zero,
        xAxis: Vector3(1, 0, 0),
        yAxis: Vector3(0, 1, 0),
        zAxis: Vector3(0, 0, 1),
      ),
    ];
    expect(
      frames.where((frame) => frame.kind == RecognitionFrameKind.wcs),
      isEmpty,
    );
  });

  test('axis inversion preserves the anchor and reverses the direction', () {
    final editor = _editor();
    editor.setAxis(const Vector3(0, 0, -1), source: 'manual');
    expect(editor.target.axis.toJson(), [0.0, 0.0, -1.0]);
    expect(editor.target.origin.toJson(), [0.0, 0.0, 0.0]);
  });

  test('orientation changes preserve the recognized center anchor', () {
    final editor = _editor();
    editor.setAxis(const Vector3(1, 0, 0), source: 'global:X');
    expect(editor.target.origin.toJson(), [0.0, 0.0, 0.0]);
    expect(editor.target.anchor, 'recognized-center');
  });

  test('reset restores measured diameter, axis and anchor', () {
    final editor = _editor();
    editor.setDiameter(18);
    editor.setAxis(const Vector3(1, 0, 0), source: 'global:X');
    editor.reset();
    expect(editor.target.diameter, 17.964);
    expect(editor.target.axis.toJson(), [0.0, 0.0, 1.0]);
    expect(editor.target.axisSource, 'recognized');
  });

  test(
    'cancel marks the editor cancelled without mutating measured values',
    () {
      final editor = _editor();
      editor.setDiameter(18);
      editor.cancel();
      expect(editor.state, RecognitionParameterEditorState.cancelled);
      expect(editor.measured.parameters['diameter'], 17.964);
    },
  );

  test('invalid, NaN and infinite dimensions are rejected', () {
    final editor = _editor();
    editor.setDiameter(0);
    expect(editor.error, isNotNull);
    editor.setDiameter(double.nan);
    expect(editor.error, isNotNull);
    editor.setDiameter(double.infinity);
    expect(editor.error, isNotNull);
  });

  test('stale mesh or selection fingerprint blocks a proposal', () {
    final editor = _editor();
    expect(
      editor.isStaleFor(
        meshFingerprint: 'mesh-fingerprint-other',
        selectionFingerprint: 'selection-a',
        selectionRevision: 1,
      ),
      isTrue,
    );
    expect(
      editor.isStaleFor(
        meshFingerprint: 'mesh-fingerprint-a',
        selectionFingerprint: 'selection-other',
        selectionRevision: 2,
      ),
      isTrue,
    );
  });

  test('nominal correction recalculates RMS against the original points', () {
    final editor = _editor();
    final measuredRms = editor.metrics.rms;
    editor.setDiameter(18);
    expect(editor.metrics.rms, isNot(measuredRms));
    expect(editor.metrics.maximum, greaterThan(0));
  });

  test('measured fitting metrics remain separate from corrected metrics', () {
    final editor = _editor();
    editor.setDiameter(18);
    expect(editor.measured.parameters['diameter'], 17.964);
    expect(editor.proposal.metrics.diameterDelta, closeTo(.036, 1e-12));
  });

  test('preview state is transient editor state, not measured geometry', () {
    final editor = _editor();
    editor.setDiameter(18);
    editor.state = RecognitionParameterEditorState.previewActive;
    expect(editor.state, RecognitionParameterEditorState.previewActive);
    expect(editor.measured.parameters['diameter'], 17.964);
  });

  test('confirmed parameters remain a proposal and do not create a BRep', () {
    final editor = _editor();
    editor.confirm();
    expect(editor.state, RecognitionParameterEditorState.confirmed);
    expect(editor.proposal.measured.type, 'cylinder');
  });
}
