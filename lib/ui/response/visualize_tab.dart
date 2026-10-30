import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/scripting/script_engine.dart';
import '../../theme.dart';
import '../help_tip.dart';

/// Shows `pm.visualizer.set` output: the HTML rendered statically (no
/// scripts run), or its source.
class VisualizeView extends StatefulWidget {
  const VisualizeView({super.key, required this.output});

  final VisualizerOutput output;

  @override
  State<VisualizeView> createState() => _VisualizeViewState();
}

class _VisualizeViewState extends State<VisualizeView> {
  bool _source = false;

  bool get _hasScript =>
      RegExp(r'<script\b', caseSensitive: false).hasMatch(widget.output.html);

  Future<bool> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return true; // in-page anchors and other schemes do nothing
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final html = widget.output.html;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'Rendered shows the page the template built; HTML shows its '
                'source.',
                title: 'Visualizer view',
                example: '<table>…</table>',
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Rendered')),
                    ButtonSegment(value: true, label: Text('HTML')),
                  ],
                  selected: {_source},
                  onSelectionChanged: (s) => setState(() => _source = s.first),
                ),
              ),
              HelpHover(
                'Copies the generated HTML.',
                title: 'Copy HTML',
                child: IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: html));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('HTML copied')),
                    );
                  },
                ),
              ),
              if (_hasScript && !_source)
                HelpHover(
                  'The template has <script> tags. They don\'t run here, so '
                  'charts or tables drawn by script (pm.getData) stay '
                  'empty; the static HTML is shown.',
                  title: 'Scripts are not run',
                  child: Text(
                    'Scripts in the template are not run',
                    style: TextStyle(fontSize: 12, color: Palette.textDim),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: _source
                ? SelectableText(
                    html,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.45,
                      color: Palette.text,
                    ),
                  )
                : DefaultTextStyle.merge(
                    style: TextStyle(color: Palette.text, fontSize: 13.5),
                    child: HtmlWidget(
                      html,
                      onTapUrl: _open,
                      onErrorBuilder: (context, element, error) => Text(
                        'Could not render <${element.localName}>: $error',
                        style: TextStyle(color: Palette.danger, fontSize: 12),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
