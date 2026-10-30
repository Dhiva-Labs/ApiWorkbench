import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/models.dart';
import '../../services/net_config.dart';
import '../../theme.dart';
import '../adaptive.dart';
import '../help_tip.dart';

/// Lets the user choose a certificate or key file; returns its path, or null
/// when cancelled. Replaced in tests, which cannot open a native picker.
@visibleForTesting
Future<String?> Function(String title) certFilePicker = _pickCertFile;

Future<String?> _pickCertFile(String title) async {
  final picked = await FilePicker.platform.pickFiles(
    dialogTitle: title,
    // Certificate and key files have no common extension or MIME type, and
    // phone pickers grey out files they cannot classify.
    type: FileType.any,
  );
  final path = picked?.files.singleOrNull?.path;
  if (path == null) return null;
  if (!(Platform.isAndroid || Platform.isIOS)) return path;
  // Phone pickers hand over a copy in the cache folder, which the system may
  // clear; keep one where it stays.
  try {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'certs'),
    );
    await dir.create(recursive: true);
    final name = '${DateTime.now().millisecondsSinceEpoch}-${p.basename(path)}';
    return (await File(path).copy(p.join(dir.path, name))).path;
  } catch (_) {
    return path;
  }
}

/// The proxy variables of [environment], passwords hidden, one line each;
/// empty when none is set.
List<String> systemProxySummary(Map<String, String> environment) {
  String? pick(String upper) {
    final v = environment[upper.toLowerCase()] ?? environment[upper];
    return v == null || v.trim().isEmpty ? null : v.trim();
  }

  String hide(String value) => value.replaceFirstMapped(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)?[^@/]*@'),
    (m) => '${m.group(1) ?? ''}***@',
  );

  return [
    for (final name in ['HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY'])
      if (pick(name) case final value?)
        '$name  ${name == 'NO_PROXY' ? value : hide(value)}',
  ];
}

bool _exists(String path) {
  try {
    final home = Platform.environment['HOME'] ?? '';
    return File(
      path.startsWith('~/') ? home + path.substring(1) : path,
    ).existsSync();
  } catch (_) {
    return false;
  }
}

/// Proxy, CA certificate and client certificate settings, edited in place
/// on [network] (issues #14 and #15).
class NetworkSettingsSection extends StatefulWidget {
  const NetworkSettingsSection({
    super.key,
    required this.network,
    required this.onChanged,
  });

  final NetworkSettings network;
  final VoidCallback onChanged;

  @override
  State<NetworkSettingsSection> createState() => _NetworkSettingsSectionState();
}

class _NetworkSettingsSectionState extends State<NetworkSettingsSection> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _bypass = TextEditingController();
  final _ca = TextEditingController();
  bool _showPassword = false;

  NetworkSettings get net => widget.network;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NetworkSettingsSection old) {
    super.didUpdateWidget(old);
    if (!identical(old.network, widget.network)) _load();
  }

  void _load() {
    _host.text = net.proxyHost;
    _port.text = '${net.proxyPort}';
    _user.text = net.proxyUser;
    _password.text = net.proxyPassword;
    _bypass.text = net.proxyBypass;
    _ca.text = net.caCertPath;
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password, _bypass, _ca]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed(VoidCallback edit) {
    setState(edit);
    widget.onChanged();
  }

  int? get _portValue {
    final v = int.tryParse(_port.text.trim());
    return v != null && v >= 1 && v <= 65535 ? v : null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Proxy',
          'Where requests go on their way out. Most home networks need none; '
              'company networks often require one.',
        ),
        _modePicker(),
        const SizedBox(height: 10),
        ...switch (net.proxyMode) {
          ProxyMode.none => [_note('Requests connect straight to the server.')],
          ProxyMode.system => _systemNote(),
          ProxyMode.custom => _customFields(),
        },
        const SizedBox(height: 18),
        _heading(
          'CA certificate',
          'A certificate authority to trust on top of the ones your device '
              'already knows. Needed for servers that use a private or '
              'company CA.',
        ),
        _caField(),
        const SizedBox(height: 18),
        _heading(
          'Client certificates',
          'Certificates the app presents to servers that ask who you are '
              '(mutual TLS), chosen by the server\'s host name.',
        ),
        ..._certList(),
      ],
    );
  }

  // ---- Proxy ---------------------------------------------------------------

  Widget _modePicker() {
    const labels = {
      ProxyMode.none: 'None',
      ProxyMode.system: 'System',
      ProxyMode.custom: 'Custom',
    };
    const help = {
      ProxyMode.none:
          'Connect straight to servers, even if your computer is set up to '
          'use a proxy.',
      ProxyMode.system:
          'Use the HTTP_PROXY, HTTPS_PROXY and NO_PROXY environment '
          'variables the app was started with.',
      ProxyMode.custom:
          'Send requests through the proxy you enter below. Hosts on the '
          'bypass list still connect directly.',
    };
    return SegmentedButton<ProxyMode>(
      showSelectedIcon: false,
      segments: [
        for (final m in ProxyMode.values)
          ButtonSegment(
            value: m,
            label: HelpHover(
              help[m]!,
              title: '${labels[m]} proxy',
              example: m == ProxyMode.system
                  ? 'HTTPS_PROXY=http://proxy.corp:3128'
                  : null,
              child: Text(labels[m]!, style: const TextStyle(fontSize: 12.5)),
            ),
          ),
      ],
      selected: {net.proxyMode},
      onSelectionChanged: (sel) => _changed(() => net.proxyMode = sel.first),
    );
  }

  List<Widget> _systemNote() {
    final lines = systemProxySummary(Platform.environment);
    return [
      _note(
        lines.isEmpty
            ? 'No proxy variables are set where the app was started, so '
                  'requests connect directly. Set HTTP_PROXY, HTTPS_PROXY '
                  'and NO_PROXY and restart the app, or choose Custom.'
            : 'Read from the environment the app was started with:',
      ),
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SelectableText(
            line,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Palette.text,
            ),
          ),
        ),
    ];
  }

  List<Widget> _customFields() {
    final credentialsOk =
        net.proxyUser.isEmpty ||
        ProxyEndpoint(
          'proxy',
          1,
          user: net.proxyUser,
          password: net.proxyPassword,
        ).credentialsFitInProxyString;
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _field(
              controller: _host,
              label: 'Host',
              hint: 'proxy.example.com',
              help:
                  'The name or address of your HTTP proxy. A pasted URL such '
                  'as http://proxy.example.com:3128 works too.',
              example: 'proxy.corp.example',
              onChanged: (v) => _changed(() => net.proxyHost = v),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 112,
            child: _field(
              controller: _port,
              label: 'Port',
              help:
                  'The port the proxy listens on, from 1 to 65535. Common '
                  'ones are 3128 and 8080.',
              example: '8080',
              keyboard: TextInputType.number,
              formatters: [FilteringTextInputFormatter.digitsOnly],
              error: _portValue == null ? '1 to 65535' : null,
              onChanged: (v) => _changed(() {
                final port = _portValue;
                if (port != null) net.proxyPort = port;
              }),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      _pair(
        _field(
          controller: _user,
          label: 'Username (optional)',
          help:
              'Only if the proxy asks for a login. Sent as Basic '
              'authentication.',
          example: 'ada',
          onChanged: (v) => _changed(() => net.proxyUser = v),
        ),
        _field(
          controller: _password,
          label: 'Password',
          obscure: !_showPassword,
          help:
              'The proxy password. It is saved in the app\'s settings file '
              'as plain text.',
          trailing: [
            _iconButton(
              icon: _showPassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              help: _showPassword ? 'Hide the password.' : 'Show the password.',
              title: _showPassword ? 'Hide' : 'Show',
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ],
          onChanged: (v) => _changed(() => net.proxyPassword = v),
        ),
      ),
      if (!credentialsOk) ...[
        const SizedBox(height: 6),
        _note(
          'HTTP/1.1 requests cannot send this login: a ";" or spaces at '
          'either end, a ":" in the username, or an empty password. Change '
          'it, or use HTTP/2 (https only).',
          warn: true,
        ),
      ],
      const SizedBox(height: 10),
      _field(
        controller: _bypass,
        label: 'Bypass list',
        hint: 'localhost, 127.0.0.1, *.internal.test',
        help:
            'Hosts that skip the proxy, separated by commas. A name also '
            'covers its subdomains; *.suffix covers subdomains only. IP '
            'addresses, ranges like 10.0.0.0/8 and :port are understood.',
        example: 'localhost, 127.0.0.1, *.corp.test, 10.0.0.0/8',
        maxLines: 3,
        onChanged: (v) => _changed(() => net.proxyBypass = v),
      ),
      const SizedBox(height: 6),
      _note(
        'HTTP proxies only (https goes through CONNECT). SOCKS is not '
        'supported.',
      ),
    ];
  }

  // ---- CA certificate ------------------------------------------------------

  Widget _caField() {
    final path = net.caCertPath.trim();
    final missing = path.isNotEmpty && !_exists(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _field(
          controller: _ca,
          label: 'CA certificate file (PEM)',
          hint: 'No extra CA',
          help:
              'A .pem or .crt file with one or more CA certificates. They '
              'are trusted in addition to the system certificates.',
          example: '/etc/ssl/corp-ca.pem',
          error: missing ? 'File not found' : null,
          trailing: [
            if (net.caCertPath.isNotEmpty)
              _iconButton(
                icon: Icons.clear,
                help: 'Stop trusting this extra CA.',
                title: 'Clear',
                onPressed: () => _changed(() {
                  net.caCertPath = '';
                  _ca.clear();
                }),
              ),
            _iconButton(
              icon: Icons.folder_open_outlined,
              help: 'Choose the CA certificate file.',
              title: 'Choose file',
              onPressed: () async {
                final picked = await certFilePicker(
                  'Choose the CA certificate',
                );
                if (picked == null || !mounted) return;
                _changed(() {
                  net.caCertPath = picked;
                  _ca.text = picked;
                });
              },
            ),
          ],
          onChanged: (v) => _changed(() => net.caCertPath = v.trim()),
        ),
        const SizedBox(height: 4),
        _note(
          path.isEmpty
              ? 'Only the system certificates are trusted.'
              : 'Trusted in addition to the system certificates.',
        ),
      ],
    );
  }

  // ---- Client certificates -------------------------------------------------

  List<Widget> _certList() {
    final certs = net.clientCerts;
    return [
      if (certs.isEmpty)
        _note('None. Add one if a server asks for a client certificate.')
      else
        for (final cert in certs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CertTile(
              cert: cert,
              onToggle: (v) => _changed(() => cert.enabled = v),
              onEdit: () async {
                final edited = await showClientCertificateDialog(
                  context,
                  existing: cert,
                );
                if (edited == null || !mounted) return;
                _changed(() {
                  final i = net.clientCerts.indexWhere((c) => c.id == cert.id);
                  if (i >= 0) net.clientCerts[i] = edited;
                });
              },
              onRemove: () => _changed(
                () => net.clientCerts.removeWhere((c) => c.id == cert.id),
              ),
            ),
          ),
      const SizedBox(height: 2),
      Align(
        alignment: Alignment.centerLeft,
        child: HelpHover(
          'Present a certificate to one host or a family of hosts. You pick '
          'the files and the host name pattern.',
          title: 'Add client certificate',
          example: '*.example.com',
          child: OutlinedButton.icon(
            onPressed: () async {
              final added = await showClientCertificateDialog(context);
              if (added == null || !mounted) return;
              _changed(() => net.clientCerts.add(added));
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add certificate'),
          ),
        ),
      ),
    ];
  }

  // ---- Shared bits ---------------------------------------------------------

  Widget _heading(String text, String help) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: LabelWithHelp(
      text,
      help,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: Palette.textDim,
      ),
    ),
  );

  Widget _note(String text, {bool warn = false}) => Text(
    text,
    style: TextStyle(
      fontSize: 11.5,
      height: 1.4,
      color: warn ? Palette.delete : Palette.textDim,
    ),
  );

  /// Two fields side by side, stacked when there is no room.
  Widget _pair(Widget a, Widget b) => LayoutBuilder(
    builder: (context, box) => box.maxWidth >= 380
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 8),
              Expanded(child: b),
            ],
          )
        : Column(children: [a, const SizedBox(height: 10), b]),
  );

  Widget _iconButton({
    required IconData icon,
    required String help,
    required String title,
    required VoidCallback onPressed,
  }) => _FieldIconButton(
    icon: icon,
    help: help,
    title: title,
    onPressed: onPressed,
  );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String help,
    required ValueChanged<String> onChanged,
    String? hint,
    String? example,
    String? error,
    bool obscure = false,
    int maxLines = 1,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
    List<Widget> trailing = const [],
  }) => _NetField(
    controller: controller,
    label: label,
    help: help,
    onChanged: onChanged,
    hint: hint,
    example: example,
    error: error,
    obscure: obscure,
    maxLines: maxLines,
    keyboard: keyboard,
    formatters: formatters,
    trailing: trailing,
  );
}

/// A small icon button for the inside of a text field, at least 44 px on
/// touch screens.
class _FieldIconButton extends StatelessWidget {
  const _FieldIconButton({
    required this.icon,
    required this.help,
    required this.title,
    required this.onPressed,
  });

  final IconData icon;
  final String help;
  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final side = isTouch(context) ? minTouchTarget : 32.0;
    return HelpHover(
      help,
      title: title,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints(minWidth: side, minHeight: side),
        padding: EdgeInsets.zero,
        iconSize: 18,
        onPressed: onPressed,
        icon: Icon(icon, color: Palette.textDim),
      ),
    );
  }
}

/// A text field with a help icon (tap on phones, hover on desktop) and
/// optional buttons inside its right edge.
class _NetField extends StatelessWidget {
  const _NetField({
    required this.controller,
    required this.label,
    required this.help,
    required this.onChanged,
    this.hint,
    this.example,
    this.error,
    this.obscure = false,
    this.maxLines = 1,
    this.keyboard,
    this.formatters,
    this.trailing = const [],
  });

  final TextEditingController controller;
  final String label;
  final String help;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? example;
  final String? error;
  final bool obscure;
  final int maxLines;
  final TextInputType? keyboard;
  final List<TextInputFormatter>? formatters;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    obscureText: obscure,
    maxLines: obscure ? 1 : maxLines,
    minLines: 1,
    keyboardType: keyboard,
    inputFormatters: formatters,
    autocorrect: false,
    enableSuggestions: false,
    style: const TextStyle(fontSize: 13),
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
      isDense: !isTouch(context),
      suffixIcon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...trailing,
          HelpTip(help, title: label, example: example),
        ],
      ),
      suffixIconConstraints: const BoxConstraints(minHeight: 32),
    ),
  );
}

/// One row of the client certificate list.
class _CertTile extends StatelessWidget {
  const _CertTile({
    required this.cert,
    required this.onToggle,
    required this.onEdit,
    required this.onRemove,
  });

  final ClientCertificate cert;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final pfx = cert.pfxPath.isNotEmpty;
    final files = pfx
        ? [cert.pfxPath]
        : [cert.certPath, if (cert.keyPath.isNotEmpty) cert.keyPath];
    final missing = files.where((f) => f.isNotEmpty && !_exists(f)).toList();
    final touch = isTouch(context);
    final side = touch ? minTouchTarget : 32.0;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          cert.host.isEmpty ? '(no host)' : cert.host,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cert.enabled ? Palette.text : Palette.textDim,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${pfx ? 'PFX' : 'PEM'}  ${files.map(p.basename).join(', ')}',
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
          style: TextStyle(fontSize: 11.5, color: Palette.textDim),
        ),
        if (missing.isNotEmpty)
          Text(
            'File not found: ${missing.map(p.basename).join(', ')}',
            style: TextStyle(fontSize: 11.5, color: Palette.delete),
          ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HelpHover(
          cert.enabled
              ? 'In use. Switch off to keep the entry without sending it.'
              : 'Switched off: this certificate is not sent.',
          title: 'Use this certificate',
          child: Switch(
            value: cert.enabled,
            onChanged: onToggle,
            materialTapTargetSize: touch
                ? MaterialTapTargetSize.padded
                : MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        HelpHover(
          'Change the host, files or passphrase.',
          title: 'Edit',
          child: IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints(minWidth: side, minHeight: side),
            iconSize: 18,
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ),
        HelpHover(
          'Remove this entry. The files stay where they are.',
          title: 'Remove',
          child: IconButton(
            visualDensity: VisualDensity.compact,
            constraints: BoxConstraints(minWidth: side, minHeight: side),
            iconSize: 18,
            onPressed: onRemove,
            icon: Icon(Icons.delete_outline, color: Palette.delete),
          ),
        ),
      ],
    );
    final icon = Padding(
      padding: const EdgeInsets.only(right: 8, top: 1),
      child: Icon(
        pfx ? Icons.inventory_2_outlined : Icons.badge_outlined,
        size: 17,
        color: Palette.accent,
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.border),
      ),
      // Beside the details when there is room, underneath on phones.
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 340
            ? Row(
                children: [
                  icon,
                  Expanded(child: info),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      icon,
                      Expanded(child: info),
                    ],
                  ),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              ),
      ),
    );
  }
}

/// Adds or edits a client certificate. Returns the entry to keep (a copy,
/// with [existing]'s id when editing), or null when cancelled.
Future<ClientCertificate?> showClientCertificateDialog(
  BuildContext context, {
  ClientCertificate? existing,
}) => showDialog<ClientCertificate>(
  context: context,
  builder: (_) => _ClientCertificateDialog(existing: existing),
);

class _ClientCertificateDialog extends StatefulWidget {
  const _ClientCertificateDialog({this.existing});

  final ClientCertificate? existing;

  @override
  State<_ClientCertificateDialog> createState() =>
      _ClientCertificateDialogState();
}

class _ClientCertificateDialogState extends State<_ClientCertificateDialog> {
  late final _host = TextEditingController(text: widget.existing?.host ?? '');
  late final _cert = TextEditingController(
    text: widget.existing?.certPath ?? '',
  );
  late final _key = TextEditingController(text: widget.existing?.keyPath ?? '');
  late final _pfx = TextEditingController(text: widget.existing?.pfxPath ?? '');
  late final _passphrase = TextEditingController(
    text: widget.existing?.passphrase ?? '',
  );
  late bool _usePfx = widget.existing?.pfxPath.isNotEmpty ?? false;
  bool _showPassphrase = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_host, _cert, _key, _pfx, _passphrase]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final host = _host.text.trim();
    final String? error;
    if (host.isEmpty) {
      error = 'Enter the host name this certificate is for.';
    } else if (_usePfx && _pfx.text.trim().isEmpty) {
      error = 'Choose the PFX / P12 file.';
    } else if (!_usePfx && _cert.text.trim().isEmpty) {
      error = 'Choose the certificate file.';
    } else {
      error = null;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(
      context,
      ClientCertificate(
        id: widget.existing?.id,
        host: host,
        certPath: _usePfx ? '' : _cert.text.trim(),
        keyPath: _usePfx ? '' : _key.text.trim(),
        pfxPath: _usePfx ? _pfx.text.trim() : '',
        passphrase: _passphrase.text,
        enabled: widget.existing?.enabled ?? true,
      ),
    );
  }

  Future<void> _pick(TextEditingController into, String title) async {
    final path = await certFilePicker(title);
    if (path == null || !mounted) return;
    setState(() {
      into.text = path;
      _error = null;
    });
  }

  Widget _pathField(
    TextEditingController controller, {
    required String label,
    required String help,
    required String pickTitle,
    String? example,
  }) {
    final path = controller.text.trim();
    return _NetField(
      controller: controller,
      label: label,
      help: help,
      example: example,
      error: path.isNotEmpty && !_exists(path) ? 'File not found' : null,
      onChanged: (_) => setState(() => _error = null),
      trailing: [
        _FieldIconButton(
          icon: Icons.folder_open_outlined,
          help: 'Pick the file from your device.',
          title: 'Choose file',
          onPressed: () => _pick(controller, pickTitle),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final save = FilledButton(onPressed: _save, child: const Text('Save'));
    return AdaptiveDialog(
      width: 520,
      primary: save,
      title: Row(
        children: [
          Icon(Icons.badge_outlined, size: 20, color: Palette.accent),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              editing ? 'Edit client certificate' : 'Add client certificate',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        save,
      ],
      content: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _NetField(
              controller: _host,
              label: 'Host',
              hint: 'api.example.com',
              help:
                  'The server this certificate is for. *.example.com covers '
                  'its subdomains, and :8443 limits it to one port. The most '
                  'specific entry wins.',
              example: 'api.example.com:8443',
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 14),
            HelpHover(
              'PEM: a certificate file and a key file (or one file with '
              'both). PFX / P12: a single password-protected bundle.',
              title: 'Certificate format',
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('PEM files', style: TextStyle(fontSize: 12.5)),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('PFX / P12', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
                selected: {_usePfx},
                onSelectionChanged: (sel) => setState(() {
                  _usePfx = sel.first;
                  _error = null;
                }),
              ),
            ),
            const SizedBox(height: 14),
            if (_usePfx)
              _pathField(
                _pfx,
                label: 'PFX / P12 file',
                help:
                    'A .pfx or .p12 bundle holding the certificate and its '
                    'private key.',
                pickTitle: 'Choose the PFX or P12 file',
                example: 'client.p12',
              )
            else ...[
              _pathField(
                _cert,
                label: 'Certificate file (PEM)',
                help:
                    'The client certificate, a .pem or .crt file. Add the '
                    'intermediate certificates after it if the server needs '
                    'them.',
                pickTitle: 'Choose the certificate file',
                example: 'client.pem',
              ),
              const SizedBox(height: 10),
              _pathField(
                _key,
                label: 'Key file (PEM)',
                help:
                    'The private key that goes with the certificate. Leave '
                    'it empty if the certificate file also contains the key.',
                pickTitle: 'Choose the private key file',
                example: 'client.key',
              ),
            ],
            const SizedBox(height: 10),
            _NetField(
              controller: _passphrase,
              label: _usePfx
                  ? 'Passphrase (optional)'
                  : 'Key passphrase (optional)',
              obscure: !_showPassphrase,
              help:
                  'Unlocks the PFX file, or an encrypted private key. Leave '
                  'it empty when there is none. It is saved in the app\'s '
                  'settings file as plain text.',
              onChanged: (_) {},
              trailing: [
                _FieldIconButton(
                  icon: _showPassphrase
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  help: _showPassphrase
                      ? 'Hide the passphrase.'
                      : 'Show the passphrase.',
                  title: _showPassphrase ? 'Hide' : 'Show',
                  onPressed: () =>
                      setState(() => _showPassphrase = !_showPassphrase),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: Palette.delete),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
