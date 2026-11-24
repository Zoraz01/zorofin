import 'dart:async';

import 'package:flutter/material.dart';

import '../../watch_together.dart';
import '../theme.dart';
import '../widgets/focusable.dart';
import 'settings_screen.dart';

/// Watch together from Profile (Apple `WatchTogetherView`). No group
/// controls are added over browsing or video.
class WatchTogetherScreen extends StatefulWidget {
  const WatchTogetherScreen({
    super.key,
    required this.group,
    this.preview = false,
  });

  final WatchTogether group;
  final bool preview;

  @override
  State<WatchTogetherScreen> createState() => _WatchTogetherScreenState();
}

class _WatchTogetherScreenState extends State<WatchTogetherScreen> {
  final _name = TextEditingController(text: 'Movie night');
  bool _creating = false;
  bool _confirmingLeave = false;
  String? _groupId;
  Timer? _refresh;

  WatchTogether get _group => widget.group;

  @override
  void initState() {
    super.initState();
    _groupId = _group.group?.id;
    _group.addListener(_changed);
    _name.addListener(() => setState(() {}));
    if (!widget.preview) {
      unawaited(_group.refresh());
      _refresh = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_group.refresh()),
      );
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _group.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (_group.group?.id != _groupId) {
        _groupId = _group.group?.id;
        _creating = false;
        _confirmingLeave = false;
      }
    });
  }

  /// Back steps out of a confirmation or the create form first.
  bool get _hasInnerStep => _confirmingLeave || _creating;

  void _stepBack() => setState(() {
    if (_confirmingLeave) {
      _confirmingLeave = false;
    } else {
      _creating = false;
    }
  });

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final joined = group.group;
    return PopScope(
      canPop: !_hasInnerStep,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stepBack();
      },
      child: SettingsScaffold(
        title: _creating ? 'Start a group' : 'Watch together',
        actions: [
          ZoroButton(
            label: _hasInnerStep ? 'Back' : 'Done',
            onPressed: () =>
                _hasInnerStep ? _stepBack() : Navigator.of(context).maybePop(),
          ),
        ],
        children: [
          if (widget.preview)
            const _Lead(
              'Connect to your Jellyfin server to create or join a group.',
            )
          else if (joined != null)
            ..._joined(group)
          else if (_creating)
            ..._createForm(group)
          else if (group.canJoin)
            ..._groupList(group)
          else
            const _Lead(
              'Your server has not enabled group watching for this account.',
            ),
          if (group.busy) const SettingsFootnote('Updating group…'),
          if (group.error != null) ...[
            SettingsFootnote(group.error!),
            SettingsAction(
              title: 'Refresh groups',
              enabled: !group.busy,
              onPressed: () => unawaited(group.refresh()),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _joined(WatchTogether group) {
    final joined = group.group!;
    final item = group.currentItem;
    return [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Zoro.panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your group', style: Zoro.font(20, color: Zoro.muted)),
            const SizedBox(height: 6),
            Text(
              joined.groupName,
              style: Zoro.font(30, weight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              item?.displayTitle ?? 'Choose something to watch',
              style: Zoro.font(22, color: Zoro.muted),
            ),
            if (joined.state == 'Waiting')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Waiting for others…',
                  style: Zoro.font(22, color: Zoro.jade),
                ),
              ),
          ],
        ),
      ),
      const SettingsSectionHeader('Participants'),
      for (final name in joined.participants)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Zoro.jade,
                child: Text(
                  name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                  style: Zoro.font(
                    22,
                    weight: FontWeight.w700,
                    color: Zoro.background,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Text(name, style: Zoro.font(24)),
            ],
          ),
        ),
      const SizedBox(height: 12),
      if (_confirmingLeave) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Text(
            'Leave this group?',
            style: Zoro.font(26, weight: FontWeight.w600),
          ),
        ),
        SettingsAction(
          title: 'Leave group',
          destructive: true,
          enabled: !group.busy,
          onPressed: () async {
            await group.leave();
            if (mounted) setState(() => _confirmingLeave = false);
            await group.refresh();
          },
        ),
        SettingsAction(
          title: 'Stay in group',
          onPressed: () => setState(() => _confirmingLeave = false),
        ),
      ] else ...[
        if (item != null)
          SettingsAction(
            title: 'Continue watching',
            icon: Icons.play_arrow_rounded,
            enabled: !group.busy,
            onPressed: () => unawaited(group.continueWatching()),
          )
        else
          SettingsAction(
            title: 'Browse library',
            icon: Icons.video_library_rounded,
            onPressed: group.requestBrowse,
          ),
        SettingsAction(
          title: 'Leave group',
          enabled: !group.busy,
          onPressed: () => setState(() => _confirmingLeave = true),
        ),
      ],
    ];
  }

  List<Widget> _createForm(WatchTogether group) => [
    const _Lead('Create a group, then choose something from your library.'),
    SettingsTextField(
      label: 'Group name',
      controller: _name,
      enabled: !group.busy,
      autofocus: true,
      onSubmitted: (_) => unawaited(group.create(_name.text)),
    ),
    SettingsAction(
      title: 'Create group',
      enabled: !group.busy && _name.text.trim().isNotEmpty,
      onPressed: () => unawaited(group.create(_name.text)),
    ),
  ];

  List<Widget> _groupList(WatchTogether group) => [
    const _Lead('Join a group or start your own.'),
    const SettingsSectionHeader('Available groups'),
    if (group.groups.isEmpty)
      const SettingsFootnote('No groups right now')
    else
      for (final g in group.groups)
        SettingsAction(
          title: 'Join ${g.groupName}',
          subtitle:
              '${g.participants.length} ${g.participants.length == 1 ? 'person' : 'people'}',
          icon: Icons.groups_rounded,
          enabled: !group.busy,
          onPressed: () => unawaited(group.join(g)),
        ),
    if (group.canCreate)
      SettingsAction(
        title: 'Start a group',
        icon: Icons.add_rounded,
        enabled: !group.busy,
        onPressed: () => setState(() => _creating = true),
      ),
  ];
}

class _Lead extends StatelessWidget {
  const _Lead(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
    child: Text(text, style: Zoro.font(24, color: Zoro.muted)),
  );
}
