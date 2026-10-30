import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/cookie_jar.dart';
import '../services/cookie_store.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'adaptive.dart';
import 'help_tip.dart';

/// Browse and edit the cookie jar (issue #12): domains with their cookies,
/// search, add or edit with a Set-Cookie line, delete, clear.
Future<void> showCookieManager(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const CookieManager());

/// `2026-10-31 12:00`, in local time.
String formatCookieDate(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

/// `Session`, `Expires 2026-11-01 14:03` or `Expired`, for a cookie at [now].
String cookieExpiryText(DateTime? expires, [DateTime? now]) {
  if (expires == null) return 'Session';
  if (!expires.isAfter((now ?? DateTime.now()).toUtc())) return 'Expired';
  return 'Expires ${formatCookieDate(expires)}';
}

TextStyle get _mono => TextStyle(
  fontFamily: 'monospace',
  fontSize: 12.5,
  height: 1.4,
  color: Palette.text,
);

/// A small labelled badge for one cookie attribute, with hover help.
class CookieChip extends StatelessWidget {
  const CookieChip(
    this.label, {
    super.key,
    required this.help,
    this.title,
    this.example,
    this.color,
  });

  final String label;
  final String help;
  final String? title;
  final String? example;
  final Color? color;

  @override
  Widget build(BuildContext context) => HelpHover(
    help,
    title: title ?? label,
    example: example,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: (color ?? Palette.textDim).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: color ?? Palette.textDim,
        ),
      ),
    ),
  );
}

/// The attribute badges shared by the cookie manager and the Cookies tab.
/// Only the attributes passed in are shown.
List<Widget> cookieChips({
  String? domain,
  bool? hostOnly,
  String? path,
  DateTime? expires,
  bool showExpiry = true,
  int? maxAge,
  bool secure = false,
  bool httpOnly = false,
  String? sameSite,
}) => [
  if (domain != null)
    CookieChip(
      hostOnly == false ? 'Domain $domain' : 'Host $domain',
      title: hostOnly == false ? 'Domain cookie' : 'Host-only cookie',
      help: hostOnly == false
          ? 'Sent to this domain and all its subdomains, because the server '
                'set a Domain attribute.'
          : 'Sent only to this exact host, not to its subdomains. This is '
                'what a cookie without a Domain attribute gets.',
    ),
  if (path != null)
    CookieChip(
      'Path $path',
      title: 'Path',
      help: 'The cookie is only sent to URLs under this path.',
      example: '/api  also covers  /api/users',
    ),
  if (maxAge != null)
    CookieChip(
      'Max-Age $maxAge',
      help:
          'Seconds the cookie lives, counted from when it arrived. It wins '
          'over Expires, and 0 or less deletes the cookie.',
    ),
  if (showExpiry)
    CookieChip(
      cookieExpiryText(expires),
      title: 'Expiry',
      help: expires == null
          ? 'A session cookie has no expiry date. ApiWorkbench keeps it until '
                'you delete it, even after a restart.'
          : 'The cookie is dropped after this time (shown in your local '
                'time; UTC ${expires.toUtc().toIso8601String()}).',
    ),
  if (secure)
    CookieChip(
      'Secure',
      color: Palette.get_,
      help:
          'Only sent over https. Requests to localhost and 127.0.0.1 count '
          'as secure, as in browsers.',
    ),
  if (httpOnly)
    CookieChip(
      'HttpOnly',
      color: Palette.put,
      help:
          'Browsers hide it from page scripts. ApiWorkbench still shows and '
          'sends it.',
    ),
  if (sameSite != null)
    CookieChip(
      'SameSite $sameSite',
      color: Palette.patch,
      title: 'SameSite',
      help:
          'Tells browsers when to send the cookie on cross-site requests. '
          'ApiWorkbench shows it but always sends the cookie.',
    ),
];

/// One cookie: name, value and attribute badges. The manager passes
/// [onEdit] and [onDelete]; the response tab shows it read-only.
class CookieTile extends StatelessWidget {
  const CookieTile({
    super.key,
    required this.cookie,
    this.showDomain = false,
    this.onEdit,
    this.onDelete,
  });

  final StoredCookie cookie;

  /// Show the domain badge (the manager already groups by domain).
  final bool showDomain;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = cookie;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt,
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SelectableText(
                    c.name,
                    maxLines: 1,
                    style: _mono.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (onEdit != null)
                HelpHover(
                  'Change this cookie\'s value or attributes.',
                  title: 'Edit cookie',
                  essential: true,
                  child: IconButton(
                    key: Key('cookie-edit-${c.name}'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: onEdit,
                  ),
                ),
              if (onDelete != null)
                HelpHover(
                  'Remove this cookie from the jar.',
                  title: 'Delete cookie',
                  essential: true,
                  child: IconButton(
                    key: Key('cookie-delete-${c.name}'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Palette.delete,
                    ),
                    onPressed: onDelete,
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 2, bottom: 6),
            child: SelectableText(
              c.value.isEmpty ? '(empty value)' : c.value,
              maxLines: 3,
              style: _mono.copyWith(
                color: c.value.isEmpty ? Palette.textDim : Palette.text,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 5,
              children: cookieChips(
                domain: showDomain ? c.domain : null,
                hostOnly: c.hostOnly,
                path: c.path,
                expires: c.expires,
                secure: c.secure,
                httpOnly: c.httpOnly,
                sameSite: c.sameSite,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The cookie manager dialog; full screen on phones.
class CookieManager extends StatefulWidget {
  const CookieManager({super.key});

  @override
  State<CookieManager> createState() => _CookieManagerState();
}

class _CookieManagerState extends State<CookieManager> {
  final _search = TextEditingController();

  /// The domain the user picked. Phones start on the domain list (null);
  /// wide layouts show the first domain until one is picked.
  String? _selected;

  /// The domain whose cookies were on screen at the last build, so "Add"
  /// can pre-fill it.
  String? _shown;

  PersistentCookieJar get _jar => context.read<AppState>().cookies;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _query => _search.text.trim().toLowerCase();

  /// Domains matching the search: by name, or holding a cookie named so.
  List<({String domain, int count})> _domains() {
    final q = _query;
    final all = _jar.domains();
    if (q.isEmpty) return all;
    return [
      for (final d in all)
        if (d.domain.contains(q) ||
            _jar
                .cookiesIn(d.domain)
                .any((c) => c.name.toLowerCase().contains(q)))
          d,
    ];
  }

  /// The cookies of [domain] to show: all when the domain matched the
  /// search, else only the ones whose name did.
  List<StoredCookie> _cookies(String domain) {
    final all = _jar.cookiesIn(domain);
    final q = _query;
    if (q.isEmpty || domain.contains(q)) return all;
    return [
      for (final c in all)
        if (c.name.toLowerCase().contains(q)) c,
    ];
  }

  Future<void> _edit({StoredCookie? cookie, String? domain}) async {
    final result = await showDialog<StoredCookie>(
      context: context,
      builder: (_) => _CookieEditor(cookie: cookie, domain: domain),
    );
    if (result == null || !mounted) return;
    if (cookie == null) {
      _jar.add(result);
    } else {
      _jar.update(cookie, result);
    }
    setState(() => _selected = result.domain);
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('cookie-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Palette.delete,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _clearDomain(String domain, int count) async {
    final ok = await _confirm(
      'Clear cookies for $domain?',
      'Removes $count cookie${count == 1 ? '' : 's'} saved for this domain.',
      'Clear domain',
    );
    if (!ok || !mounted) return;
    _jar.clearDomain(domain);
    setState(() => _selected = null);
  }

  Future<void> _clearAll() async {
    final n = _jar.count;
    if (n == 0) return;
    final ok = await _confirm(
      'Clear every cookie?',
      'Removes all $n cookies from the jar. You will be signed out of '
          'sites that use them.',
      'Clear all cookies',
    );
    if (!ok || !mounted) return;
    _jar.clear();
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) {
    final jar = _jar;
    return StreamBuilder<void>(
      stream: jar.changes,
      builder: (context, _) => AdaptiveDialog(
        width: 860,
        height: 540,
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        title: const Text('Cookies'),
        headerActions: [
          HelpHover(
            'Add a cookie by typing its Set-Cookie line and the domain it '
            'belongs to.',
            title: 'Add cookie',
            essential: true,
            child: IconButton(
              key: const Key('cookie-add'),
              icon: const Icon(Icons.add),
              onPressed: () => _edit(domain: _shown),
            ),
          ),
          HelpHover(
            'Remove every cookie from every domain.',
            title: 'Clear all',
            essential: true,
            child: IconButton(
              key: const Key('cookie-clear-all'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: jar.count == 0 ? null : _clearAll,
            ),
          ),
        ],
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
        content: LayoutBuilder(
          builder: (context, box) {
            if (jar.count == 0) return _empty();
            final domains = _domains();
            final wide = box.maxWidth >= 560;
            final names = domains.map((d) => d.domain).toSet();
            var selected = _selected;
            if (selected != null && !names.contains(selected)) selected = null;
            if (wide && selected == null && domains.isNotEmpty) {
              selected = domains.first.domain;
            }
            _shown = selected;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 250, child: _domainPane(domains, selected)),
                  VerticalDivider(width: 24, color: Palette.border),
                  Expanded(child: _cookiePane(selected, back: false)),
                ],
              );
            }
            return selected == null
                ? _domainPane(domains, null)
                : _cookiePane(selected, back: true);
          },
        ),
      ),
    );
  }

  Widget _empty() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cookie_outlined, size: 40, color: Palette.textDim),
          const SizedBox(height: 12),
          const Text('No cookies yet', style: TextStyle(fontSize: 15)),
          const SizedBox(height: 6),
          Text(
            'Cookies that servers set appear here, and are sent back on '
            'later requests. You can also add one yourself.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a cookie'),
          ),
        ],
      ),
    ),
  );

  Widget _domainPane(
    List<({String domain, int count})> domains,
    String? selected,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      HelpHover(
        'Narrows the list to domains whose name, or one of whose cookie '
        'names, contains your text.',
        title: 'Search cookies',
        example: 'session',
        child: TextField(
          key: const Key('cookie-search'),
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search domains and names',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: domains.isEmpty
            ? Center(
                child: Text(
                  'No domains match.',
                  style: TextStyle(color: Palette.textDim),
                ),
              )
            : ListView.builder(
                itemCount: domains.length,
                itemBuilder: (_, i) => _domainRow(
                  domains[i].domain,
                  domains[i].count,
                  domains[i].domain == selected,
                ),
              ),
      ),
    ],
  );

  Widget _domainRow(String domain, int count, bool on) => Material(
    color: on ? Palette.accentSoft : Colors.transparent,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selected = domain),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: minTouchTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  domain,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              HelpHover(
                '$count cookie${count == 1 ? '' : 's'} saved for $domain.',
                title: 'Cookie count',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Palette.surfaceAlt,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(fontSize: 11.5, color: Palette.textDim),
                  ),
                ),
              ),
              if (isPhoneWidth(context))
                Icon(Icons.chevron_right, size: 18, color: Palette.textDim),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _cookiePane(String? domain, {required bool back}) {
    if (domain == null) {
      return Center(
        child: Text(
          'No domain to show.',
          style: TextStyle(color: Palette.textDim),
        ),
      );
    }
    final cookies = _cookies(domain);
    final total = _jar.cookiesIn(domain).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (back)
              IconButton(
                tooltip: 'All domains',
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: () => setState(() => _selected = null),
              ),
            Expanded(
              child: Text(
                domain,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            HelpHover(
              'Remove every cookie saved for $domain.',
              title: 'Clear domain',
              child: TextButton.icon(
                key: const Key('cookie-clear-domain'),
                style: TextButton.styleFrom(foregroundColor: Palette.delete),
                onPressed: () => _clearDomain(domain, total),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear domain'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: cookies.isEmpty
              ? Center(
                  child: Text(
                    'No cookies match.',
                    style: TextStyle(color: Palette.textDim),
                  ),
                )
              : ListView.builder(
                  itemCount: cookies.length,
                  itemBuilder: (_, i) => CookieTile(
                    cookie: cookies[i],
                    onEdit: () => _edit(cookie: cookies[i]),
                    onDelete: () => _jar.delete(cookies[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Add or edit one cookie as a Set-Cookie line plus the domain it is filed
/// under. Pops the new [StoredCookie], or null on cancel.
class _CookieEditor extends StatefulWidget {
  const _CookieEditor({this.cookie, this.domain});

  final StoredCookie? cookie;
  final String? domain;

  @override
  State<_CookieEditor> createState() => _CookieEditorState();
}

class _CookieEditorState extends State<_CookieEditor> {
  late final _domain = TextEditingController(
    text: widget.cookie?.domain ?? widget.domain ?? '',
  );
  late final _line = TextEditingController(
    text: widget.cookie?.toSetCookieLine() ?? 'name=value; Path=/',
  );
  String? _error;

  void _save() {
    try {
      Navigator.pop(context, cookieFromLine(_line.text, _domain.text));
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.cookie != null;
    final save = FilledButton(
      key: const Key('cookie-save'),
      onPressed: _save,
      child: const Text('Save'),
    );
    return ControllerScope(
      controllers: [_domain, _line],
      child: AdaptiveDialog(
        width: 520,
        title: Text(editing ? 'Edit cookie' : 'Add cookie'),
        primary: save,
        actions: [
          TextButton(
            key: const Key('cookie-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          save,
        ],
        content: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LabelWithHelp(
                'Domain',
                'The host the cookie belongs to. Add Domain=… to the line '
                    'below to share it with subdomains too.',
                example: 'api.example.com',
              ),
              const SizedBox(height: 6),
              TextField(
                key: const Key('cookie-domain'),
                controller: _domain,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'api.example.com',
                ),
              ),
              const SizedBox(height: 14),
              const LabelWithHelp(
                'Set-Cookie line',
                'The cookie as a server would send it: name=value, then '
                    'optional attributes separated by semicolons (Path, '
                    'Domain, Expires, Max-Age, Secure, HttpOnly, SameSite).',
                example: 'session=abc123; Path=/; Secure; Max-Age=3600',
              ),
              const SizedBox(height: 6),
              TextField(
                key: const Key('cookie-line'),
                controller: _line,
                minLines: 3,
                maxLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                style: _mono,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'name=value; Path=/',
                  errorText: _error,
                  errorMaxLines: 3,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
