import 'package:flutter_test/flutter_test.dart';
import 'package:zorofin_tv/core/home.dart';
import 'package:zorofin_tv/core/server_extras.dart';

void main() {
  test(
    'hashes preserve native persistence keys and unsigned ordering on web',
    () {
      final cases = [
        ('', '-340d631b7bdddcdb', '5472609002491880229'),
        ('hello', '32964f71b2764b97', '2607821981565500683'),
        ('Viewer|Library|2026', '7c5343c12a55a726', '-9180789902469748870'),
        ('日本語 🎬', '78b87cc5ed5a1c23', '-8137712940842092798'),
      ];
      for (final c in cases) {
        expect(stableHash(c.$1), c.$2);
        expect(stableHashInt(c.$1).toString(), c.$3);
      }
    },
  );
  test(
    'SplitMix64 matches native fixtures without JavaScript integer loss',
    () {
      final expected = {
        0: [3767, 7850, 2839, 1222, 7373, 1045, 3456, 3470],
        1: [1232, 4259, 5295, 117, 4380, 5024, 3522, 266],
        7: [7243, 7902, 4673, 6101, 1837, 4152, 5899, 4591],
        -1: [1968, 4484, 8500, 8921, 7303, 4537, 482, 8258],
      };
      for (final entry in expected.entries) {
        final random = HomeRandom(entry.key);
        expect(List.generate(8, (_) => random.nextInt(10000)), entry.value);
      }
    },
  );
}
