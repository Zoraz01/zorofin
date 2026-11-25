/// Minimal notification surface for shared controllers outside Flutter.
/// Flutter builds use the framework's own ChangeNotifier via notifier.dart.
class ChangeNotifier {
  final _listeners = <void Function()>[];
  bool _disposed = false;
  void addListener(void Function() listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    if (_disposed) return;
    for (final listener in List.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}
