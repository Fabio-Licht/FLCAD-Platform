import 'package:flutter/services.dart';

import '../layout/panel_identity.dart';

/// Small Windows-only seam for the native owner/owned relationship.
///
/// The bridge carries only a stable panel id. HWNDs remain native and never
/// cross an engine or the Dart/CAD boundary.
final class PanelWindowNativeBridge {
  static const MethodChannel _channel = MethodChannel(
    'flcad.panel.native_window',
  );

  static Future<bool> registerPanel(PanelId panelId) async {
    try {
      return await _channel.invokeMethod<bool>('registerPanel', {
            'panelId': panelId.name,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> bindPanel(PanelId panelId) async {
    try {
      return await _channel.invokeMethod<bool>('bindPanel', {
            'panelId': panelId.name,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> unregisterPanel(PanelId panelId) async {
    try {
      await _channel.invokeMethod<void>('unregisterPanel', {
        'panelId': panelId.name,
      });
    } on MissingPluginException {
      // Non-Windows and older runners simply do not have native ownership.
    } on PlatformException {
      // Window teardown must remain best effort.
    }
  }
}
