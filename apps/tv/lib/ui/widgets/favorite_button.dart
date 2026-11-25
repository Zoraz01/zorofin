import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/errors.dart';
import '../../core/models.dart';
import '../theme.dart';
import 'focusable.dart';

/// Heart toggle that writes the favorite to the server (Apple `FavoriteButton`).
class FavoriteButton extends StatefulWidget {
  const FavoriteButton({
    super.key,
    required this.item,
    required this.catalog,
    this.labeled = false,
  });

  final MediaItem item;
  final Catalog catalog;
  final bool labeled;

  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  bool? _value;
  bool _busy = false;

  bool get _favorite => _value ?? widget.item.userData?.isFavorite ?? false;

  Future<void> _toggle() async {
    if (_busy) return;
    final next = !_favorite;
    setState(() => _busy = true);
    try {
      final result = await widget.catalog.setFavorite(widget.item, next);
      if (mounted) setState(() => _value = result);
    } on ClientError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.labeled) {
      return ZoroButton(
        label: _favorite ? 'Favorited' : 'Favorite',
        icon: _favorite
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        onPressed: _toggle,
      );
    }
    return CircleIconButton(
      icon: _favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      color: _favorite ? Zoro.jade : Zoro.text,
      filled: false,
      label: _favorite ? 'Remove from favorites' : 'Add to favorites',
      onPressed: _toggle,
    );
  }
}
