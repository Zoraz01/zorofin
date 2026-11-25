/// Downward-only single-stream adaptation; smooth playback never raises quality. A decision reconnects at the current
/// position; this is not a claim of seamless multi-variant HLS switching.
class AdaptiveQuality {
  AdaptiveQuality(this.ceiling);
  final int ceiling;
  static const ladder = [
    2000000,
    4000000,
    8000000,
    12000000,
    20000000,
    40000000,
    60000000,
    80000000,
    120000000,
  ];
  double? _last, _position;
  double _grace = 10, _stall = 0, _cooldown = 0;
  bool _counted = false;
  final List<double> _stalls = [];
  String? reason;

  int? sample({
    required double now,
    required double position,
    required int bitrate,
    required bool enabled,
    required bool ready,
    required bool paused,
    required bool seeking,
    required bool buffering,
    double bufferedAhead = 0,
    int? sourceBitrate,
  }) {
    if (!now.isFinite || !position.isFinite) return null;
    final elapsed = _last == null ? 0.0 : (now - _last!).clamp(0.0, 3.0);
    final jumped =
        _position != null && (position - _position!).abs() > elapsed * 3 + 3;
    _last = now;
    _position = position;
    if (!enabled || !ready || paused || seeking || jumped) {
      _stall = 0;
      _counted = false;
      _stalls.clear();
      _grace = 10;
      return null;
    }
    if (_grace > 0) {
      _grace -= elapsed;
      return null;
    }
    _stalls.removeWhere((t) => now - t > 60);
    if (buffering) {
      _stall += elapsed;
      if (_stall >= 2 && !_counted) {
        _stalls.add(now);
        _counted = true;
      }
      if (now >= _cooldown && (_stall >= 6 || _stalls.length >= 2)) {
        final source = sourceBitrate != null && sourceBitrate > 0
            ? sourceBitrate
            : bitrate;
        final target = (source < bitrate ? source : bitrate) * .8;
        final choices = ladder.where(
          (v) => v < bitrate && v <= target && v <= ceiling,
        );
        if (choices.isNotEmpty) {
          final next = choices.last;
          _changed(now);
          reason = 'Reduced after buffering';
          return next;
        }
      }
    } else {
      _stall = 0;
      _counted = false;
    }
    return null;
  }

  void _changed(double now) {
    _stall = 0;
    _counted = false;
    _stalls.clear();
    _cooldown = now + 45;
    _grace = 10;
  }
}
