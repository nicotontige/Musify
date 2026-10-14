/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     Musify is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about Musify, including how to contribute,
 *     please visit: https://github.com/gokadzev/Musify
 */

import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:musify/constants/app_constants.dart';
import 'package:musify/extensions/l10n.dart';
import 'package:musify/main.dart' show logger;
import 'package:musify/services/data_manager.dart';
import 'package:musify/services/lastfm_client.dart';
import 'package:musify/services/listenbrainz_client.dart';
import 'package:musify/services/scrobbling_service.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/utilities/flutter_toast.dart';
import 'package:musify/utilities/url_launcher.dart';
import 'package:musify/widgets/custom_bar.dart';
import 'package:musify/widgets/mini_player_bottom_space.dart';

/// Where the user connects a scrobbling account.
///
/// Musify sends nothing until an account is connected here, and the Last.fm
/// entry only appears in builds that were given an API key.
class ScrobblingPage extends StatefulWidget {
  const ScrobblingPage({super.key});

  @override
  State<ScrobblingPage> createState() => _ScrobblingPageState();
}

class _ScrobblingPageState extends State<ScrobblingPage> {
  @override
  void initState() {
    super.initState();
    scrobblingService.loadFromStorage();
    unawaited(
      scrobblingService.refreshPendingCount().catchError((
        error,
        StackTrace stackTrace,
      ) {
        logger.log(
          'Error reading pending listens',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n!.scrobbling)),
      body: SingleChildScrollView(
        padding: commonSingleChildScrollViewPadding,
        child: Column(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: scrobblingEnabled,
              builder: (_, enabled, __) => CustomBar(
                context.l10n!.scrobbling,
                FluentIcons.channel_share_24_regular,
                description: context.l10n!.scrobblingDescription,
                borderRadius: commonCustomBarRadiusFirst,
                trailing: Switch(
                  value: enabled,
                  onChanged: _toggleScrobbling,
                ),
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: scrobblingService.listenBrainzUsername,
              builder: (_, username, __) => CustomBar(
                'ListenBrainz',
                FluentIcons.cloud_sync_24_regular,
                description: username ?? context.l10n!.notConnected,
                trailing: _accountButton(
                  isConnected: username != null,
                  onConnect: _connectListenBrainz,
                  onDisconnect: scrobblingService.disconnectListenBrainz,
                ),
              ),
            ),
            if (isLastFmSupported)
              ValueListenableBuilder<String?>(
                valueListenable: scrobblingService.lastFmUsername,
                builder: (_, username, __) => CustomBar(
                  'Last.fm',
                  FluentIcons.music_note_2_24_regular,
                  description: username ?? context.l10n!.notConnected,
                  trailing: _accountButton(
                    isConnected: username != null,
                    onConnect: _connectLastFm,
                    onDisconnect: scrobblingService.disconnectLastFm,
                  ),
                ),
              ),
            ValueListenableBuilder<int>(
              valueListenable: scrobblingService.pendingListens,
              builder: (_, pending, __) => CustomBar(
                context.l10n!.pendingListens,
                FluentIcons.arrow_sync_24_regular,
                description: pending == 0
                    ? context.l10n!.pendingListensNone
                    : context.l10n!.pendingListensDescription(pending),
                borderRadius: commonCustomBarRadiusLast,
                onTap: pending == 0 ? null : _submitPending,
              ),
            ),
            const SizedBox(height: 20),
            const MiniPlayerBottomSpace(),
          ],
        ),
      ),
    );
  }

  Widget _accountButton({
    required bool isConnected,
    required Future<void> Function() onConnect,
    required Future<void> Function() onDisconnect,
  }) {
    return TextButton(
      onPressed: () => unawaited(isConnected ? onDisconnect() : onConnect()),
      child: Text(
        isConnected ? context.l10n!.disconnect : context.l10n!.connect,
      ),
    );
  }

  void _toggleScrobbling(bool value) {
    scrobblingEnabled.value = value;
    unawaited(addOrUpdateData<bool>('settings', 'scrobblingEnabled', value));
    showToast(context, context.l10n!.settingChangedMsg);
  }

  Future<void> _connectListenBrainz() async {
    final token = await _askForListenBrainzToken();
    if (token == null || token.isEmpty) return;

    final connected = await scrobblingService.connectListenBrainz(token);
    if (mounted) _reportConnection(connected);
  }

  Future<void> _connectLastFm() async {
    final authorizationUrl = await scrobblingService.beginLastFmSignIn();
    if (authorizationUrl == null) {
      if (mounted) _reportConnection(false);
      return;
    }

    try {
      await launchURL(authorizationUrl);
    } catch (e, stackTrace) {
      logger.log(
        'Error opening the Last.fm sign-in page',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) _reportConnection(false);
      return;
    }

    if (!mounted) return;
    final approved = await _askForLastFmApproval();
    if (approved != true) return;

    final connected = await scrobblingService.completeLastFmSignIn();
    if (mounted) _reportConnection(connected);
  }

  Future<void> _submitPending() async {
    await scrobblingService.submitPendingNow();
    if (!mounted) return;

    showToast(
      context,
      scrobblingService.pendingListens.value == 0
          ? context.l10n!.pendingListensNone
          : context.l10n!.error,
    );
  }

  void _reportConnection(bool connected) {
    showToast(
      context,
      connected
          ? context.l10n!.accountConnected
          : context.l10n!.accountConnectionFailed,
      icon: connected ? null : FluentIcons.error_circle_24_regular,
    );
  }

  Future<String?> _askForListenBrainzToken() async {
    final controller = TextEditingController();
    final colorScheme = Theme.of(context).colorScheme;

    try {
      return await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'ListenBrainz',
            style: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n!.listenBrainzTokenDescription,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n!.listenBrainzToken,
                  labelStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.outline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: colorScheme.primary),
                  ),
                ),
                style: TextStyle(color: colorScheme.onSurface),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () =>
                  unawaited(launchURL(Uri.parse(listenBrainzSettingsUrl))),
              child: Text(context.l10n!.getToken),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n!.cancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: Text(context.l10n!.connect),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<bool?> _askForLastFmApproval() {
    final colorScheme = Theme.of(context).colorScheme;

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Last.fm',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          context.l10n!.lastFmAuthorizationMessage,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n!.confirm),
          ),
        ],
      ),
    );
  }
}
