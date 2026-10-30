import 'package:flutter/material.dart';

import '../../theme.dart';
import '../help_tip.dart';

/// Widest a single auth field grows; wider screens leave the rest empty,
/// like Postman's auth forms.
const authFieldMaxWidth = 560.0;

/// Keeps a field at a readable width, left-aligned.
class AuthFieldBox extends StatelessWidget {
  const AuthFieldBox({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: authFieldMaxWidth),
      child: child,
    ),
  );
}

Widget _suffix(List<Widget> icons) => Padding(
  padding: const EdgeInsets.only(right: 4),
  child: Row(mainAxisSize: MainAxisSize.min, children: icons),
);

const _suffixConstraints = BoxConstraints(minWidth: 32, minHeight: 32);

/// A text field with hover help. Secret fields are obscured until the eye
/// is pressed; a multi-line secret (a private key) is shown as a summary
/// while hidden.
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.help,
    required this.title,
    this.example,
    this.hint,
    this.secret = false,
    this.multiline = false,
    this.mono = false,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String help;
  final String title;
  final String? example;
  final String? hint;
  final bool secret;
  final bool multiline;
  final bool mono;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value,
  );
  bool _reveal = false;

  @override
  void didUpdateWidget(AuthTextField old) {
    super.didUpdateWidget(old);
    // Changed elsewhere (a refreshed token, a picked saved token).
    if (widget.value != _c.text) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _eye() => IconButton(
    tooltip: _reveal ? 'Hide' : 'Show',
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    icon: Icon(
      _reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
    ),
    onPressed: () => setState(() => _reveal = !_reveal),
  );

  @override
  Widget build(BuildContext context) {
    final hidden = widget.secret && !_reveal;
    final help = HelpTip(
      widget.help,
      title: widget.title,
      example: widget.example,
    );
    final style = TextStyle(
      fontSize: 13,
      fontFamily: widget.mono ? 'monospace' : null,
    );
    if (widget.multiline && hidden && _c.text.isNotEmpty) {
      final lines = '\n'.allMatches(_c.text.trim()).length + 1;
      return AuthFieldBox(
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: widget.label,
            suffixIcon: _suffix([_eye(), help]),
            suffixIconConstraints: _suffixConstraints,
          ),
          child: Text(
            'Hidden ($lines line${lines == 1 ? '' : 's'}). Show it to edit.',
            style: TextStyle(fontSize: 13, color: Palette.textDim),
          ),
        ),
      );
    }
    return AuthFieldBox(
      child: TextField(
        controller: _c,
        obscureText: hidden && !widget.multiline,
        autocorrect: false,
        enableSuggestions: !widget.secret,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 10 : 1,
        keyboardType: widget.multiline
            ? TextInputType.multiline
            : TextInputType.text,
        style: style,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          alignLabelWithHint: widget.multiline,
          suffixIcon: _suffix([if (widget.secret) _eye(), help]),
          suffixIconConstraints: _suffixConstraints,
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// One choice of an [AuthDropdown].
class AuthOption {
  const AuthOption(this.value, this.label, [this.help]);
  final String value;
  final String label;
  final String? help;
}

/// A dropdown with help on the field and on each option.
class AuthDropdown extends StatelessWidget {
  const AuthDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.help,
    this.example,
  });

  final String label;
  final String value;
  final List<AuthOption> options;
  final ValueChanged<String> onChanged;
  final String help;
  final String? example;

  @override
  Widget build(BuildContext context) {
    final known = options.any((o) => o.value == value);
    return AuthFieldBox(
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label=$value'),
        initialValue: known ? value : options.first.value,
        isExpanded: true,
        style: TextStyle(fontSize: 13, color: Palette.text),
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: _suffix([HelpTip(help, title: label, example: example)]),
          suffixIconConstraints: _suffixConstraints,
        ),
        items: [
          for (final o in options)
            DropdownMenuItem(
              value: o.value,
              child: o.help == null
                  ? Text(o.label, overflow: TextOverflow.ellipsis)
                  : HelpHover(
                      o.help!,
                      title: o.label,
                      child: Text(o.label, overflow: TextOverflow.ellipsis),
                    ),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

/// An on/off setting with a title, a one-line explanation and help.
class AuthSwitch extends StatelessWidget {
  const AuthSwitch({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.help,
    this.example,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String help;
  final String? example;

  @override
  Widget build(BuildContext context) => AuthFieldBox(
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LabelWithHelp(
                title,
                help,
                example: example,
                style: const TextStyle(fontSize: 13.5),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.3,
                  color: Palette.textDim,
                ),
              ),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    ),
  );
}

/// Two or three exclusive choices shown side by side (Header / Query).
class AuthSegmented extends StatelessWidget {
  const AuthSegmented({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.help,
    this.example,
  });

  final String label;
  final String value;
  final List<AuthOption> options;
  final ValueChanged<String> onChanged;
  final String help;
  final String? example;

  @override
  Widget build(BuildContext context) => AuthFieldBox(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabelWithHelp(
          label,
          help,
          example: example,
          style: TextStyle(fontSize: 12, color: Palette.textDim),
        ),
        const SizedBox(height: 6),
        HelpHover(
          help,
          title: label,
          example: example,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              for (final o in options)
                ButtonSegment(
                  value: o.value,
                  label: Text(o.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            selected: {
              options.any((o) => o.value == value)
                  ? value
                  : options.first.value,
            },
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ),
      ],
    ),
  );
}

/// A heading between groups of fields.
class AuthHeading extends StatelessWidget {
  const AuthHeading(this.text, this.help, {super.key, this.example});
  final String text;
  final String help;
  final String? example;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: LabelWithHelp(
      text,
      help,
      example: example,
      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
    ),
  );
}

/// Fields most people leave alone, folded away like Postman's "Advanced".
class AuthAdvanced extends StatefulWidget {
  const AuthAdvanced({
    super.key,
    required this.children,
    this.help =
        'Optional settings. Leave them empty to use the defaults, which work '
        'for most servers.',
  });

  final List<Widget> children;
  final String help;

  @override
  State<AuthAdvanced> createState() => _AuthAdvancedState();
}

class _AuthAdvancedState extends State<AuthAdvanced> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: HelpHover(
          widget.help,
          title: 'Advanced',
          child: TextButton.icon(
            onPressed: () => setState(() => _open = !_open),
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
            label: const Text('Advanced'),
          ),
        ),
      ),
      if (_open)
        for (final c in widget.children) ...[c, const SizedBox(height: 12)],
    ],
  );
}
