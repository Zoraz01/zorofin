import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/tv_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(TvPlatform.channel, null));
  test('store lookup never opens a rating page automatically', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(TvPlatform.channel, (call) async {
      calls.add(call.method);
      return call.method == 'store' ? 'amazon' : true;
    });
    expect(await TvPlatform.store(), 'amazon');
    expect(calls, ['store']);
    expect(await TvPlatform.openRating(), true);
    expect(calls, ['store', 'openRating']);
  });
  test('unsupported ports and unavailable stores fail gracefully', () async {
    expect(await TvPlatform.store(), null);
    expect(await TvPlatform.openRating(), false);
    messenger.setMockMethodCallHandler(TvPlatform.channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await TvPlatform.store(), null);
    expect(await TvPlatform.openRating(), false);
  });
}
