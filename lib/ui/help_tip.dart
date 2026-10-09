import 'package:flutter/material.dart';

import '../theme.dart';

Color _iconColor(BuildContext c) => Palette.textDim.withValues(alpha: 0.85);
Color _textColor(BuildContext c) => Palette.text;
Color _dimColor(BuildContext c) => Palette.textDim;

/// Whether hover help is shown. The app sets it from Settings; every
/// [HelpTip] and [HelpHover] rebuilds when it changes.
final hoverHelpEnabled = ValueNotifier<bool>(true);

/// Explains a field on hover (or tap on touch screens) as a small card:
/// a bold [title], a one- or two-sentence [message], and an optional
/// [example] in code font.
class HelpTip extends StatelessWidget {
  const HelpTip(
    this.message, {
    super.key,
    this.title,
    this.example,
    this.size = 15,
  });

  final String message;
  final String? title;
  final String? example;
  final double size;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: hoverHelpEnabled,
    builder: (context, on, _) => on ? _icon(context) : const SizedBox.shrink(),
  );

  Widget _icon(BuildContext context) => HelpHover(
    message,
    triggerMode: TooltipTriggerMode.tap,
    title: title,
    example: example,
    child: MouseRegion(
      cursor: SystemMouseCursors.help,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(Icons.help_outline, size: size, color: _iconColor(context)),
      ),
    ),
  );
}

/// A field or section label followed by a [HelpTip] titled with the label.
class LabelWithHelp extends StatelessWidget {
  const LabelWithHelp(
    this.label,
    this.help, {
    super.key,
    this.style,
    this.example,
  });

  final String label;
  final String help;
  final TextStyle? style;
  final String? example;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(label, style: style, overflow: TextOverflow.ellipsis),
      ),
      HelpTip(help, title: label, example: example, size: 14),
    ],
  );
}

/// Explains any widget on hover without adding an icon (for controls whose
/// label is already visible, like segmented buttons, switches or badges).
class HelpHover extends StatelessWidget {
  const HelpHover(
    this.message, {
    super.key,
    required this.child,
    this.title,
    this.example,
    this.essential = false,
    this.triggerMode = TooltipTriggerMode.longPress,
  });

  /// Touch screens: wrapped controls keep their tap for selecting, so help
  /// shows on long-press; the standalone ⓘ of [HelpTip] uses tap. Mouse
  /// hover works either way.
  final TooltipTriggerMode triggerMode;

  final String message;
  final String? title;
  final String? example;
  final Widget child;

  /// Icon-only controls (like the navigation rail) keep a plain tooltip
  /// with just the [title] when hover help is turned off.
  final bool essential;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: hoverHelpEnabled,
    builder: (context, on, _) {
      if (on) return _card(context);
      if (essential && title != null) {
        return Tooltip(message: title!, child: child);
      }
      return child;
    },
  );

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final text = _textColor(context);
    final dim = _dimColor(context);
    final base = TextStyle(fontSize: 12.5, height: 1.45, color: text);
    return Tooltip(
      triggerMode: triggerMode,
      showDuration: const Duration(seconds: 10),
      richMessage: TextSpan(
        style: base,
        children: [
          if (title != null) ...[
            TextSpan(
              text: title,
              style: base.copyWith(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const TextSpan(text: '\n'),
          ],
          TextSpan(text: message),
          if (example != null) ...[
            TextSpan(
              text: '\nExample  ',
              style: base.copyWith(
                color: dim,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 2,
              ),
            ),
            TextSpan(
              text: example,
              style: base.copyWith(
                fontFamily: 'monospace',
                fontSize: 12,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      child: child,
    );
  }
}

/// Plain-language meaning of an HTTP method, for hover help.
({String title, String message}) httpMethodHelp(String method) =>
    switch (method.toUpperCase()) {
      'GET' => (title: 'GET', message: 'Reads data without changing anything.'),
      'POST' => (
        title: 'POST',
        message: 'Sends data to create something or trigger an action.',
      ),
      'PUT' => (
        title: 'PUT',
        message: 'Replaces a resource with the data you send.',
      ),
      'PATCH' => (
        title: 'PATCH',
        message: 'Changes part of a resource, leaving the rest as it is.',
      ),
      'DELETE' => (title: 'DELETE', message: 'Removes a resource.'),
      'HEAD' => (
        title: 'HEAD',
        message: 'Like GET, but only the headers come back, no body.',
      ),
      'OPTIONS' => (
        title: 'OPTIONS',
        message:
            'Asks which methods and headers are allowed. Browsers send it '
            'before cross-origin requests.',
      ),
      'QUERY' => (
        title: 'QUERY',
        message:
            'A safe, read-only method like GET that can carry a body, for '
            'complex searches.',
      ),
      'ANY' => (title: 'ANY', message: 'Matches every HTTP method.'),
      final m => (title: m, message: 'A custom HTTP method.'),
    };

/// Plain-language meaning of an HTTP status code, for hover help.
({String title, String message}) httpStatusHelp(int code) {
  const known = {
    200: ('200 OK', 'The request worked.'),
    201: ('201 Created', 'Something new was created.'),
    202: ('202 Accepted', 'Accepted; the work will finish later.'),
    204: ('204 No Content', 'It worked, and there is no body to return.'),
    301: ('301 Moved Permanently', 'The resource has a new address for good.'),
    302: ('302 Found', 'Temporarily redirected to another address.'),
    304: (
      '304 Not Modified',
      'Nothing changed since the copy you already have.',
    ),
    400: ('400 Bad Request', 'The request was malformed or missing something.'),
    401: ('401 Unauthorized', 'Missing or invalid credentials.'),
    403: ('403 Forbidden', 'Credentials are fine but access is not allowed.'),
    404: ('404 Not Found', 'Nothing exists at this address.'),
    405: (
      '405 Method Not Allowed',
      'This address does not accept that method.',
    ),
    408: ('408 Request Timeout', 'The server stopped waiting for the request.'),
    409: ('409 Conflict', 'Clashes with the current state, like a duplicate.'),
    415: ('415 Unsupported Media Type', 'The body format is not accepted.'),
    422: ('422 Unprocessable', 'Well-formed, but the data failed validation.'),
    429: ('429 Too Many Requests', 'Rate limited; slow down and retry later.'),
    500: ('500 Internal Server Error', 'Something broke on the server.'),
    502: ('502 Bad Gateway', 'An upstream server gave a bad answer.'),
    503: ('503 Service Unavailable', 'The server is down or overloaded.'),
    504: ('504 Gateway Timeout', 'An upstream server took too long.'),
  };
  final k = known[code];
  if (k != null) return (title: k.$1, message: k.$2);
  if (code == 0) {
    return (
      title: 'No response',
      message: 'The connection failed or was cut before a status arrived.',
    );
  }
  final cls = switch (code ~/ 100) {
    1 => 'Informational: the request is still being processed.',
    2 => 'Success: the request worked.',
    3 => 'Redirect: the resource is somewhere else.',
    4 => 'Client error: something is wrong with the request.',
    _ => 'Server error: something went wrong on the server.',
  };
  return (title: '$code', message: cls);
}
