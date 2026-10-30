import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../help_tip.dart';

/// Per-request transport settings (Postman's request Settings tab).
class RequestSettingsTab extends StatefulWidget {
  const RequestSettingsTab({
    super.key,
    required this.request,
    required this.onChanged,
  });

  final RequestModel request;
  final VoidCallback onChanged;

  @override
  State<RequestSettingsTab> createState() => _RequestSettingsTabState();
}

class _RequestSettingsTabState extends State<RequestSettingsTab> {
  RequestSettings get s => widget.request.settings;

  void _set(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.select<AppState, AppSettings>((st) => st.settings);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _tri(
          'Follow redirects',
          'Follow 3xx responses to their Location.',
          s.followRedirects,
          app.followRedirects,
          (v) => _set(() => s.followRedirects = v),
        ),
        _number(
          'Maximum redirects',
          s.maxRedirects,
          app.maxRedirects,
          (v) => _set(() => s.maxRedirects = v),
        ),
        _toggle(
          'Keep the original method',
          'On 301 and 302, resend POST, PUT, … instead of switching to GET.',
          s.followOriginalMethod,
          (v) => _set(() => s.followOriginalMethod = v),
        ),
        _toggle(
          'Keep Authorization on redirects to other hosts',
          'Normally the header is dropped when a redirect leaves the '
              'original host, so credentials are not leaked.',
          s.followAuthorizationHeader,
          (v) => _set(() => s.followAuthorizationHeader = v),
        ),
        _toggle(
          'Remove Referer on redirects',
          'Do not send the Referer header on redirected requests.',
          s.removeRefererOnRedirect,
          (v) => _set(() => s.removeRefererOnRedirect = v),
        ),
        const Divider(height: 24),
        _tri(
          'Verify TLS certificates',
          'Off accepts self-signed certificates for this request only.',
          s.verifySsl,
          app.verifySsl,
          (v) => _set(() => s.verifySsl = v),
        ),
        _toggle(
          'Encode URL automatically',
          'Percent-encode characters in the URL and params that need it. '
              'Off sends them as typed, as far as a valid URL allows.',
          s.encodeUrl,
          (v) => _set(() => s.encodeUrl = v),
        ),
        _toggle(
          'Use the cookie jar',
          app.cookiesEnabled
              ? 'Send stored cookies and keep the ones this response sets.'
              : 'The cookie jar is off in Settings.',
          s.useCookies,
          (v) => _set(() => s.useCookies = v),
        ),
        _number(
          'Timeout (ms)',
          s.timeoutMs,
          app.receiveTimeoutS * 1000,
          (v) => _set(() => s.timeoutMs = v),
          min: 100,
          max: 3600000,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: s.isDefault
                ? null
                : () => _set(() => widget.request.settings = RequestSettings()),
            icon: const Icon(Icons.restart_alt, size: 16),
            label: const Text('Reset to defaults'),
          ),
        ),
      ],
    );
  }

  Widget _label(String title, String subtitle) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 13.5)),
      const SizedBox(height: 2),
      Text(
        subtitle,
        style: TextStyle(fontSize: 11.5, height: 1.3, color: Palette.textDim),
      ),
    ],
  );

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: _label(title, subtitle)),
        Switch(value: value, onChanged: onChanged),
      ],
    ),
  );

  /// On / Off / the app's default.
  Widget _tri(
    String title,
    String subtitle,
    bool? value,
    bool appDefault,
    ValueChanged<bool?> onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _label(title, subtitle),
        ),
        HelpHover(
          'Default follows Settings (currently ${appDefault ? 'on' : 'off'}).',
          title: title,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 0,
                label: Text('Default (${appDefault ? 'on' : 'off'})'),
              ),
              const ButtonSegment(value: 1, label: Text('On')),
              const ButtonSegment(value: 2, label: Text('Off')),
            ],
            selected: {
              value == null
                  ? 0
                  : value
                  ? 1
                  : 2,
            },
            onSelectionChanged: (sel) => onChanged(switch (sel.first) {
              1 => true,
              2 => false,
              _ => null,
            }),
          ),
        ),
      ],
    ),
  );

  Widget _number(
    String title,
    int? value,
    int appDefault,
    ValueChanged<int?> onChanged, {
    int min = 0,
    int max = 100,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 13.5))),
        SizedBox(
          width: 140,
          child: TextFormField(
            initialValue: value?.toString() ?? '',
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Default ($appDefault)',
            ),
            onChanged: (t) {
              final n = int.tryParse(t.trim());
              onChanged(n?.clamp(min, max));
            },
          ),
        ),
      ],
    ),
  );
}
