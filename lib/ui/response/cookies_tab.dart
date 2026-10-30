import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../services/cookie_jar.dart';
import '../../state/app_state.dart';
import '../../theme.dart';
import '../cookies_dialog.dart';
import '../help_tip.dart';

/// The Cookies tab of a response: the cookies it set, with every attribute
/// (and a note when the jar ignores or deletes one), and the cookies the jar
/// holds for the final URL, which the next request sends.
class ResponseCookies extends StatelessWidget {
  const ResponseCookies({super.key, required this.response});

  final ResponseData response;

  @override
  Widget build(BuildContext context) {
    final raw = [
      for (final e in response.headers.entries)
        if (e.key.toLowerCase() == 'set-cookie') ...e.value,
    ];
    final parsed = Uri.tryParse(response.finalUrl ?? '');
    final Uri? url = parsed != null && parsed.host.isNotEmpty ? parsed : null;
    final state = _appState(context);
    final now = DateTime.now().toUtc();

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _heading(
          'Set by this response',
          raw.length,
          'The Set-Cookie headers of this response, taken apart. The jar '
              'stores them for the URL they came from, so later requests to '
              'it send them back.',
        ),
        if (raw.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'This response set no cookies.',
              style: TextStyle(color: Palette.textDim),
            ),
          )
        else
          for (final r in raw) _SetCookieCard(raw: r, url: url, now: now),
        const SizedBox(height: 6),
        if (url != null && state != null) _JarSection(state: state, url: url),
      ],
    );
  }

  static AppState? _appState(BuildContext context) {
    try {
      return Provider.of<AppState>(context, listen: false);
    } on ProviderNotFoundException {
      return null; // Rendered on its own, without the app around it.
    }
  }
}

Widget _heading(String title, int count, String help, {Widget? trailing}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Flexible(
            child: LabelWithHelp(
              count == 0 ? title : '$title ($count)',
              help,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) ...[const Spacer(), trailing],
        ],
      ),
    );

TextStyle get _mono => TextStyle(
  fontFamily: 'monospace',
  fontSize: 12.5,
  height: 1.4,
  color: Palette.text,
);

/// One Set-Cookie header value, parsed.
class _SetCookieCard extends StatelessWidget {
  const _SetCookieCard({
    required this.raw,
    required this.url,
    required this.now,
  });

  final String raw;
  final Uri? url;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final sc = SetCookie.parse(raw);
    String? problem;
    String? note;
    if (sc == null) {
      problem = 'Not a cookie: there is no name=value pair.';
    } else if (url != null) {
      final verdict = evaluateSetCookie(sc, url!, now: now);
      if (verdict.rejection != null) {
        problem = 'Ignored by the jar: ${verdict.rejection}';
      } else if (verdict.cookie!.isExpired(now)) {
        note =
            'Deletes this cookie from the jar (Max-Age or Expires is in the '
            'past).';
      }
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sc != null) ...[
            SelectableText(
              sc.name,
              style: _mono.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            SelectableText(
              sc.value.isEmpty ? '(empty value)' : sc.value,
              maxLines: 4,
              style: _mono.copyWith(
                color: sc.value.isEmpty ? Palette.textDim : Palette.text,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: cookieChips(
                domain: sc.domain,
                hostOnly: false,
                path: sc.path,
                maxAge: sc.maxAge,
                expires: sc.expires,
                showExpiry: sc.maxAge == null,
                secure: sc.secure,
                httpOnly: sc.httpOnly,
                sameSite: sc.sameSite,
              ),
            ),
          ],
          if (problem != null) _notice(Icons.block, problem, Palette.warning),
          if (note != null)
            _notice(Icons.delete_outline, note, Palette.textDim),
          const SizedBox(height: 8),
          SelectableText(
            raw,
            style: _mono.copyWith(fontSize: 11.5, color: Palette.textDim),
          ),
        ],
      ),
    );
  }

  Widget _notice(IconData icon, String text, Color color) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ),
      ],
    ),
  );
}

/// The jar's cookies for the response URL, live.
class _JarSection extends StatelessWidget {
  const _JarSection({required this.state, required this.url});

  final AppState state;
  final Uri url;

  @override
  Widget build(BuildContext context) {
    final jar = state.cookies;
    return StreamBuilder<void>(
      stream: jar.changes,
      builder: (context, _) {
        final cookies = jar.matching(url);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _heading(
              'Cookies in the jar for this URL',
              cookies.length,
              'What the cookie jar would send with the next request to '
                  '${url.origin}${url.path.isEmpty ? '/' : url.path}: the '
                  'cookies whose domain, path and Secure flag match.',
              trailing: HelpHover(
                'Open the cookie manager to edit or delete cookies.',
                title: 'Manage cookies',
                child: TextButton.icon(
                  onPressed: () => showCookieManager(context),
                  icon: const Icon(Icons.cookie_outlined, size: 16),
                  label: const Text('Manage'),
                ),
              ),
            ),
            if (!state.settings.cookiesEnabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'The cookie jar is turned off in Settings, so requests '
                  'send none of these.',
                  style: TextStyle(fontSize: 12.5, color: Palette.warning),
                ),
              ),
            if (cookies.isEmpty)
              Text(
                'No cookies in the jar for this URL.',
                style: TextStyle(color: Palette.textDim),
              )
            else
              for (final c in cookies) CookieTile(cookie: c, showDomain: true),
          ],
        );
      },
    );
  }
}
