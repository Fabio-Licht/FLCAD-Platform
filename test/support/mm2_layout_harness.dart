import 'dart:ui' show Offset, Size;

import 'dart:io';

import 'package:flcad_mobile/app/desktop/layout/display_service.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';

/// Deterministic desktops for the MM2 layout tests.
///
/// Coordinates are physical pixels, exactly like Win32 reports them, so a
/// monitor placed left/above the primary one legitimately has negative
/// coordinates and the tests never assume an origin at (0, 0).
DisplayInfo testDisplay({
  required String deviceName,
  Offset origin = Offset.zero,
  Size size = const Size(1920, 1080),
  Size? workAreaSize,
  double scaleFactor = 1,
  bool isPrimary = false,
}) {
  final work = workAreaSize ?? Size(size.width, size.height - 40);
  return DisplayInfo(
    deviceName: deviceName,
    bounds: origin & size,
    workArea: origin & work,
    scaleFactor: scaleFactor,
    dpi: defaultDpi * scaleFactor,
    isPrimary: isPrimary,
  );
}

FakeDisplayService singleDisplayDesktop({double scaleFactor = 1}) =>
    FakeDisplayService([
      testDisplay(
        deviceName: r'\\.\DISPLAY1',
        scaleFactor: scaleFactor,
        isPrimary: true,
      ),
    ]);

FakeDisplayService dualDisplayDesktop({
  Offset secondaryOrigin = const Offset(1920, 0),
  double primaryScale = 1,
  double secondaryScale = 1,
}) => FakeDisplayService([
  testDisplay(
    deviceName: r'\\.\DISPLAY1',
    scaleFactor: primaryScale,
    isPrimary: true,
  ),
  testDisplay(
    deviceName: r'\\.\DISPLAY2',
    origin: secondaryOrigin,
    scaleFactor: secondaryScale,
  ),
]);

/// File-system seam that can fail specific operations, used to prove the store
/// never destroys the last good layout.
class FaultyLayoutFileSystem implements PanelLayoutFileSystem {
  FaultyLayoutFileSystem({
    this.failRead = false,
    this.failWrite = false,
    this.failRenameWhenTargetIsLayout = false,
    this.failEnsureDirectory = false,
  });

  final bool failRead;
  final bool failWrite;

  /// Fails only the renames whose destination is the layout file itself.
  final bool failRenameWhenTargetIsLayout;
  final bool failEnsureDirectory;

  final List<String> operations = [];
  final PanelLayoutFileSystem _delegate = const IoPanelLayoutFileSystem();

  @override
  Future<bool> exists(File file) {
    operations.add('exists:${file.path}');
    return _delegate.exists(file);
  }

  @override
  Future<String> read(File file) {
    operations.add('read:${file.path}');
    if (failRead) throw const FileSystemException('read bloqueado');
    return _delegate.read(file);
  }

  @override
  Future<void> ensureDirectory(Directory directory) {
    operations.add('ensureDirectory:${directory.path}');
    if (failEnsureDirectory) {
      throw const FileSystemException('diretório bloqueado');
    }
    return _delegate.ensureDirectory(directory);
  }

  @override
  Future<void> write(File file, String contents) {
    operations.add('write:${file.path}');
    if (failWrite) throw const FileSystemException('escrita bloqueada');
    return _delegate.write(file, contents);
  }

  @override
  Future<void> rename(File from, File to) {
    operations.add('rename:${from.path}->${to.path}');
    if (failRenameWhenTargetIsLayout && to.path.endsWith('.json')) {
      throw const FileSystemException('rename bloqueado');
    }
    return _delegate.rename(from, to);
  }

  @override
  Future<void> delete(File file) {
    operations.add('delete:${file.path}');
    return _delegate.delete(file);
  }
}
