import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/catalog.dart';
import '../../core/home.dart';
import '../../core/team_suggestions.dart';
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
  final _teamSearch = TextEditingController();
  String _league = 'All';
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
    _teamSearch.dispose();
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
      await widget.extras.checkFeatures();
      if (!mounted || !identical(client, widget.catalog.client)) return;
      final teams = await client.homeTeams(
        serverFallback: widget.extras.features.legacyHomeRows,
      );
      if (!mounted || !identical(client, widget.catalog.client)) return;
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
      await widget.extras.checkFeatures();
      if (!mounted || !identical(client, widget.catalog.client)) return;
      await client.saveHomeTeams(teams);
      if (!mounted || !identical(client, widget.catalog.client)) return;
      // Keep the older server feed and the web Home in step.
      if (widget.extras.features.legacyHomeRows) {
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
        if (!CompactSettings.of(context))
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
          style: settingsFont(context, 32, weight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Follow teams to personalize upcoming sports. Everything else on Home is selected automatically.',
          style: settingsFont(context, 22, color: Zoro.muted),
        ),
        const SizedBox(height: 16),
        if (!_loaded && _error == null)
          const SettingsFootnote('Loading your teams…'),
        if (_error != null) ...[
          SettingsFootnote(_error!),
          if (!_loaded) SettingsAction(title: 'Try again', onPressed: _load),
        ],
        if (_loaded) ...[
          const SettingsSectionHeader('Suggested teams'),
          TextField(
            controller: _teamSearch,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Find a suggested team',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final league in [
                'All',
                ...teamSuggestions.map((v) => v.league).toSet(),
              ])
                ChoiceChip(
                  label: Text(league),
                  selected: _league == league,
                  onSelected: (_) => setState(() => _league = league),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final team in teamSuggestions.where(
                (v) =>
                    (_league == 'All' || v.league == _league) &&
                    v.name.toLowerCase().contains(
                      _teamSearch.text.trim().toLowerCase(),
                    ),
              ))
                FilterChip(
                  label: Text('${team.name} · ${team.league}'),
                  selected: _edited.any(
                    (v) => v.toLowerCase() == team.name.toLowerCase(),
                  ),
                  onSelected: _saving
                      ? null
                      : (selected) {
                          final values = _edited
                              .where(
                                (v) =>
                                    v.toLowerCase() != team.name.toLowerCase(),
                              )
                              .toList();
                          if (selected && values.length < 12) {
                            values.add(team.name);
                          }
                          _teams.text = values.join(', ');
                        },
                ),
            ],
          ),
          const SizedBox(height: 16),
          const SettingsSectionHeader('Your teams · Any sport'),
          SettingsTextField(
            label: 'New York Knicks, New York Yankees',
            controller: _teams,
            enabled: !_saving,
            autofocus: true,
          ),
          const SettingsFootnote(
            'Choose suggestions above or add any other teams here, separated by commas. Use names as they appear in your guide. Up to 12 teams. Home shows a game when one of your teams is on now or starts within the next hour. Leave blank to use your server’s favorite teams.',
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
