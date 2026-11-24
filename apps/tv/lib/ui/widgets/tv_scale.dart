import 'package:flutter/widgets.dart';

/// Lays the app out on a fixed 1920x1080 logical canvas and scales it to the
/// screen, so 720p, 1080p and 4K TVs share one composition.
class TvScale extends StatelessWidget {
  const TvScale({super.key, required this.child});

  static const size = Size(1920, 1080);
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = (constraints.maxWidth / size.width).clamp(
          0.1,
          constraints.maxHeight / size.height,
        );
        final media = MediaQuery.of(context);
        return Center(
          child: SizedBox(
            width: size.width * scale,
            height: size.height * scale,
            child: FittedBox(
              child: SizedBox.fromSize(
                size: size,
                child: MediaQuery(
                  data: media.copyWith(
                    size: size,
                    textScaler: TextScaler.noScaling,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
