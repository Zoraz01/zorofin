import 'models.dart';

class GuideSlot {
  const GuideSlot(this.start, this.end, this.program);
  final DateTime start, end;
  final LiveProgram? program;
}

DateTime guideWindowStart(DateTime now) =>
    DateTime(now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);

/// Clip overlapping/malformed schedules and explicitly retain gaps. Program
/// times describe broadcasts, never a promise of DVR or future playback.
List<GuideSlot> guideSlots(
  String channelId,
  List<LiveProgram> programs,
  DateTime start,
) {
  final end = start.add(const Duration(hours: 2));
  final entries =
      programs
          .where(
            (p) =>
                p.channelId == channelId &&
                p.hasSchedule &&
                p.start!.isBefore(end) &&
                p.end!.isAfter(start),
          )
          .toList()
        ..sort((a, b) => a.start!.compareTo(b.start!));
  final result = <GuideSlot>[];
  var cursor = start;
  for (final p in entries) {
    final left = p.start!.isAfter(cursor) ? p.start! : cursor,
        right = p.end!.isBefore(end) ? p.end! : end;
    if (!right.isAfter(left)) continue;
    if (left.isAfter(cursor)) result.add(GuideSlot(cursor, left, null));
    result.add(GuideSlot(left, right, p));
    cursor = right;
  }
  if (cursor.isBefore(end)) result.add(GuideSlot(cursor, end, null));
  return result;
}
