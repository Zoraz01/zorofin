import 'package:flutter/material.dart';

import '../theme.dart';
import 'focusable.dart';

/// A centered list of choices with the current one checked and focused
/// (the TV form of an Apple `Menu` / `Picker`). Returns null on Back.
Future<T?> showChoices<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  required T selected,
}) => showDialog<T>(
  context: context,
  barrierColor: const Color(0xCC000000),
  builder: (context) => Center(
    child: Container(
      width: 760,
      constraints: const BoxConstraints(maxHeight: 900),
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Zoro.panel,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Zoro.font(30, weight: FontWeight.w700)),
            const SizedBox(height: 20),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (value, label) in options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Focusable(
                        autofocus: value == selected,
                        semanticLabel: label,
                        onPressed: () => Navigator.of(context).pop(value),
                        builder: (context, focused) => AnimatedContainer(
                          duration: Zoro.focusDuration,
                          constraints: const BoxConstraints(minHeight: 64),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: focused ? Zoro.text : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 36,
                                child: value == selected
                                    ? Icon(
                                        Icons.check_rounded,
                                        color: focused
                                            ? Zoro.background
                                            : Zoro.jade,
                                      )
                                    : null,
                              ),
                              Expanded(
                                child: Text(
                                  label,
                                  style: Zoro.font(
                                    24,
                                    color: focused
                                        ? Zoro.background
                                        : Zoro.text,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);
