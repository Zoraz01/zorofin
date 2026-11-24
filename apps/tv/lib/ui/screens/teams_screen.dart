import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/home.dart';
import '../../extras_state.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'settings_screen.dart';

/// Favorite teams for the Home sports row (Apple `HomeTeamsView`).
class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key, required this.catalog, required this.extras});

  final Catalog catalog;
  final ExtrasState extras;

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  final _teams = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _teams.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _teams.dispose();
    super.dispose();
  }

  List<String> get _edited => [
    for (final t in _teams.text.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  ];

  Future<void> _load() async {
    setState(() => _error = null);
    final client = widget.catalog.client;
    if (widget.catalog.isPreview || client == null) {
      setState(() => _loaded = true);
      return;
    }
    try {
      final teams = await client.homeTeams(
        serverFallback: widget.extras.features.homeRows,
      );
      if (!mounted) return;
      setState(() {
        _teams.text = teams.join(', ');
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Your teams couldn’t load. Try again.');
      }
    }
  }

  Future<void> _save() async {
    final client = widget.catalog.client;
    if (widget.catalog.isPreview || client == null) {
      Navigator.of(context).maybePop();
      return;
    }
    final teams = _edited;
    if (!validTeams(teams)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await client.saveHomeTeams(teams);
      // Keep the older server feed and the web Home in step.
      if (widget.extras.features.homeRows) {
        try {
          await client.saveServerHomeTeams(teams);
        } catch (_) {}
      }
      if (!mounted) return;
      widget.extras.homeChanged();
      Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Your teams couldn’t be confirmed. Try Save again; saving replaces the same preferences.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid = validTeams(_edited);
    return SettingsScaffold(
      title: 'Your teams',
      actions: [
        ZoroButton(
          label: 'Close',
          onPressed: () {
            if (!_saving) Navigator.of(context).maybePop();
          },
        ),
      ],
      children: [
        Text(
          'See your teams on Home',
          style: Zoro.font(32, weight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Home shows a game when one of your teams is on now or about to start. Everything else on Home is selected automatically.',
          style: Zoro.font(22, color: Zoro.muted),
        ),
        const SizedBox(height: 16),
        if (!_loaded && _error == null)
          const SettingsFootnote('Loading your teams…'),
        if (_error != null) ...[
          SettingsFootnote(_error!),
          if (!_loaded) SettingsAction(title: 'Try again', onPressed: _load),
        ],
        if (_loaded) ...[
          const SettingsSectionHeader('Your teams'),
          SettingsTextField(
            label: 'New York Knicks, New York Yankees',
            controller: _teams,
            enabled: !_saving,
            autofocus: true,
          ),
          const SettingsFootnote(
            'Use full team names as they appear in the guide, separated by commas. Up to 12 teams. Leave blank to use the server’s favorite teams, if it has any.',
          ),
          if (!valid)
            const SettingsFootnote(
              'Use up to 12 team names, each between 3 and 64 characters.',
            ),
          SettingsAction(
            title: _saving ? 'Saving…' : 'Save teams',
            enabled: !_saving && valid,
            onPressed: _save,
          ),
        ],
      ],
    );
  }
}
