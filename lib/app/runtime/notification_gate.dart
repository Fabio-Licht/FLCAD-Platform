import 'package:flutter/foundation.dart';

/// Gates each listener, including the remainder of an ongoing notification.
/// Dependencies can drain safely before their ChangeNotifier is disposed.
mixin NotificationGate on ChangeNotifier {
  bool Function()? notificationAllowed;
  final Map<VoidCallback, List<VoidCallback>> _gatedListeners = {};

  @override
  void addListener(VoidCallback listener) {
    void gated() {
      if (notificationAllowed?.call() ?? true) listener();
    }

    super.addListener(gated);
    _gatedListeners.putIfAbsent(listener, () => []).add(gated);
  }

  @override
  void removeListener(VoidCallback listener) {
    final registrations = _gatedListeners[listener];
    if (registrations == null || registrations.isEmpty) return;
    super.removeListener(registrations.removeAt(0));
    if (registrations.isEmpty) _gatedListeners.remove(listener);
  }

  @override
  void dispose() {
    _gatedListeners.clear();
    super.dispose();
  }
}
