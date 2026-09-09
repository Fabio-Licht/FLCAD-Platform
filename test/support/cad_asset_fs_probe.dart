import 'dart:io';
import 'package:flcad_mobile/app/runtime/cad_asset_fs_native.dart';

void main(List<String> args) {
  try {
    final fs = CadAssetNativeFs(args[1]);
    fs.dispose();
    stderr.writeln('Unexpected successful root acquisition');
    exitCode = 1;
  } on ArgumentError catch (e) {
    if (args[0] != 'missing' ||
        !e.toString().contains('Failed to load dynamic library')) {
      rethrow;
    }
    stdout.writeln('EXPECTED missing helper; no fallback');
  } on StateError catch (e) {
    if (args[0] != 'abi' ||
        !e.message.contains('Incompatible CAD filesystem ABI')) {
      rethrow;
    }
    stdout.writeln('EXPECTED incompatible ABI; no mutation');
  }
}
