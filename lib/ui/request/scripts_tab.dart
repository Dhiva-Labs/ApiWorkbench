import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../theme.dart';

/// Pre-request and post-response (test) scripts of a request, run with
/// Postman's `pm` API. (Issue #10 adds the editor and snippets.)
class ScriptsTab extends StatefulWidget {
  const ScriptsTab({super.key, required this.request, required this.onChanged});

  final RequestModel request;
  final VoidCallback onChanged;

  @override
  State<ScriptsTab> createState() => _ScriptsTabState();
}

class _ScriptsTabState extends State<ScriptsTab> {
  bool _post = false;
  late final _pre = TextEditingController(
    text: widget.request.preRequestScript,
  );
  late final _test = TextEditingController(text: widget.request.testScript);

  @override
  void dispose() {
    _pre.dispose();
    _test.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.select<AppState, bool>((s) => s.scripts != null);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Pre-request')),
              ButtonSegment(value: true, label: Text('Post-response')),
            ],
            selected: {_post},
            onSelectionChanged: (s) => setState(() => _post = s.first),
          ),
          if (!engine)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Scripts are saved with the request but not run in this build.',
                style: TextStyle(fontSize: 12, color: Palette.textDim),
              ),
            ),
          const SizedBox(height: 10),
          Expanded(
            child: TextField(
              key: ValueKey(_post),
              controller: _post ? _test : _pre,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                hintText: _post
                    ? 'pm.test("Status is 200", () => pm.response.to.have.status(200));'
                    : 'pm.environment.set("now", Date.now());',
              ),
              onChanged: (v) {
                if (_post) {
                  widget.request.testScript = v;
                } else {
                  widget.request.preRequestScript = v;
                }
                widget.onChanged();
              },
            ),
          ),
        ],
      ),
    );
  }
}
