import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/runner.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'help_tip.dart';

/// Collection / request runner: fixed iterations or recurring interval runs,
/// with live results, assertion outcomes and latency statistics.
class RunnerScreen extends StatefulWidget {
  const RunnerScreen({
    super.key,
    required this.title,
    required this.requests,
    this.collectionId,
  });

  final String title;
  final List<RequestModel> requests;

  /// Collection the requests come from, for its variables.
  final String? collectionId;

  @override
  State<RunnerScreen> createState() => _RunnerScreenState();
}

class _RunnerScreenState extends State<RunnerScreen> {
  late final RunnerService _runner;
  final _iterCtrl = TextEditingController(text: '1');
  final _delayCtrl = TextEditingController(text: '0');
  final _intervalCtrl = TextEditingController(text: '30');
  final _dataCtrl = TextEditingController();
  bool _recurring = false;
  bool _showData = false;

  List<Map<String, String>>? get _dataRows => parseDataRows(_dataCtrl.text);

  @override
  void initState() {
    super.initState();
    _runner = RunnerService(context.read<AppState>().http);
  }

  @override
  void dispose() {
    _runner.dispose();
    _iterCtrl.dispose();
    _delayCtrl.dispose();
    _intervalCtrl.dispose();
    _dataCtrl.dispose();
    super.dispose();
  }

  void _start() {
    final iterations = (int.tryParse(_iterCtrl.text) ?? 1).clamp(1, 100);
    final delayMs = (int.tryParse(_delayCtrl.text) ?? 0).clamp(0, 60000);
    final intervalS = (int.tryParse(_intervalCtrl.text) ?? 30).clamp(5, 3600);
    _iterCtrl.text = '$iterations';
    _delayCtrl.text = '$delayMs';
    _intervalCtrl.text = '$intervalS';
    _runner.start(
      requests: widget.requests,
      vars: context.read<AppState>().varsFor(widget.collectionId),
      iterations: iterations,
      delayBetween: Duration(milliseconds: delayMs),
      repeatEvery: _recurring ? Duration(seconds: intervalS) : null,
      dataRows: _dataRows,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Run • ${widget.title}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      // One scroll view for settings and results, so the page never runs
      // out of height on a phone (or with the keyboard open).
      body: AnimatedBuilder(
        animation: _runner,
        builder: (context, _) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _configBar()),
            if (_showData) SliverToBoxAdapter(child: _dataPanel()),
            SliverToBoxAdapter(
              child: Divider(height: 1, color: Palette.border),
            ),
            if (_runner.results.isNotEmpty)
              SliverToBoxAdapter(child: _summaryBar()),
            _resultsList(),
          ],
        ),
      ),
    );
  }

  Widget _configBar() {
    final running = _runner.running;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          HelpHover(
            'How many requests each pass sends, one after another in this '
            'order.',
            title: 'Requests in this run',
            child: Text(
              '${widget.requests.length} request(s)',
              style: TextStyle(color: Palette.textDim, fontSize: 12.5),
            ),
          ),
          if (!_recurring && _dataRows == null)
            _numField(
              'Iterations',
              _iterCtrl,
              enabled: !running,
              help:
                  'How many times to send the whole list, from 1 to 100. '
                  'Each pass sends every request in order.',
              example: '10',
            ),
          _numField(
            'Delay between (ms)',
            _delayCtrl,
            enabled: !running,
            help:
                'Pause after each request before sending the next, in '
                'milliseconds, to avoid overloading the server.',
            example: '1000  (one second)',
          ),
          HelpHover(
            'Keep repeating the list on a timer until you press Stop. Useful '
            'for watching an endpoint over time.',
            title: 'Recurring',
            example: 'Every 60 s, all afternoon',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: _recurring,
                  onChanged: running
                      ? null
                      : (v) => setState(() => _recurring = v),
                ),
                const Text('Recurring', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
          if (_recurring)
            _numField(
              'Every (s)',
              _intervalCtrl,
              enabled: !running,
              help:
                  'Seconds to wait after one pass ends before the next one '
                  'starts, from 5 to 3600.',
              example: '300  (five minutes)',
            ),
          HelpHover(
            'Run once per row of test data. Each row\'s values become '
            '{{variables}} for that pass.',
            title: 'Test data',
            example: '[{"userId": "1"}, {"userId": "2"}]',
            child: TextButton.icon(
              onPressed: () => setState(() => _showData = !_showData),
              icon: Icon(
                _showData ? Icons.expand_less : Icons.table_rows_outlined,
                size: 16,
              ),
              label: Text(
                _dataRows == null ? 'Data' : 'Data (${_dataRows!.length} rows)',
              ),
            ),
          ),
          HelpHover(
            running
                ? 'Stop the run now, cancelling the request in flight.'
                : 'Send the requests in order. A request passes when all its '
                      'tests pass, or with no tests, when the status is below '
                      '400.',
            title: running ? 'Stop' : 'Run',
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: running ? Palette.delete : Palette.accent,
                foregroundColor: running ? Colors.white : Palette.onAccent,
              ),
              onPressed: running ? _runner.stop : _start,
              icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 17),
              label: Text(running ? 'Stop' : 'Run'),
            ),
          ),
          if (running && _runner.nextPassAt != null)
            HelpHover(
              'Waiting for the interval before the next pass. Press Stop to '
              'end the run.',
              title: 'Waiting',
              child: Text(
                'pass ${_runner.currentIteration} done — next pass shortly…',
                style: TextStyle(color: Palette.textDim, fontSize: 12),
              ),
            )
          else if (running)
            HelpHover(
              'A pass is one trip through every request in the list.',
              title: 'Pass',
              child: Text(
                'running pass ${_runner.currentIteration}…',
                style: TextStyle(color: Palette.textDim, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  /// Data-driven runs: one JSON object per iteration, merged over the
  /// active environment's variables.
  Widget _dataPanel() {
    final rows = _dataRows;
    final hasText = _dataCtrl.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _dataCtrl,
            enabled: !_runner.running,
            maxLines: 5,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: const InputDecoration(
              hintText:
                  'JSON array — one variable set per iteration:\n'
                  '[{"userId": "1"}, {"userId": "2"}, {"userId": "3"}]\n'
                  'Use them in requests as {{userId}}.',
              suffixIcon: HelpTip(
                'A JSON list of objects. Each object is one pass, and its keys '
                'override same-named variables; without Recurring, the run '
                'does one pass per row.',
                title: 'Data rows',
                example: '[{"userId": "1"}, {"userId": "2"}]',
              ),
              suffixIconConstraints: BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          Text(
            !hasText
                ? 'Leave empty to run without per-iteration data.'
                : rows == null
                ? 'Not valid yet — expected a JSON array of objects.'
                : _recurring
                ? '${rows.length} rows — cycled across recurring passes.'
                : '${rows.length} rows — the run will do ${rows.length} iterations.',
            style: TextStyle(
              fontSize: 11.5,
              color: hasText && rows == null ? Palette.delete : Palette.textDim,
            ),
          ),
        ],
      ),
    );
  }

  Widget _numField(
    String label,
    TextEditingController ctrl, {
    required bool enabled,
    required String help,
    String? example,
  }) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: ctrl,
        enabled: enabled,
        keyboardType: TextInputType.number,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(fontSize: 12, color: Palette.textDim),
          suffixIcon: HelpTip(help, title: label, example: example),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
        ),
      ),
    );
  }

  Widget _summaryBar() {
    final r = _runner;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: Palette.surface,
      child: Wrap(
        runSpacing: 8,
        children: [
          HelpHover(
            'Only the newest ${_runner.maxResults} results are listed. The '
            'counts and times cover the whole run.',
            title: 'Results shown',
            child: Padding(
              padding: const EdgeInsets.only(right: 22),
              child: Text(
                "Showing ${r.results.length} of ${r.total} results",
                style: TextStyle(color: Palette.textDim),
              ),
            ),
          ),
          _stat(
            'Passed',
            '${r.passed}',
            Palette.get_,
            'Requests whose tests all passed, or with no tests, that '
                'returned a status below 400.',
            title: 'Passed',
          ),
          _stat(
            'Failed',
            '${r.failed}',
            r.failed == 0 ? Palette.textDim : Palette.delete,
            'Requests that failed a test, returned 4xx or 5xx with no tests, '
                'or got no response at all.',
            title: 'Failed',
          ),
          _stat(
            'Avg',
            '${r.avgMs} ms',
            Palette.textDim,
            'The typical wait: total response time divided by the number of '
                'requests.',
            title: 'Average time',
            example: '120 ms',
          ),
          _stat(
            'Min',
            '${r.minMs} ms',
            Palette.textDim,
            'The fastest response in the run.',
            title: 'Fastest',
          ),
          _stat(
            'Max',
            '${r.maxMs} ms',
            Palette.textDim,
            'The slowest response in the run. Spikes here point to timeouts '
                'or a struggling server.',
            title: 'Slowest',
          ),
        ],
      ),
    );
  }

  Widget _stat(
    String label,
    String value,
    Color color,
    String help, {
    required String title,
    String? example,
  }) => HelpHover(
    help,
    title: title,
    example: example,
    child: Padding(
      padding: const EdgeInsets.only(right: 22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _resultsList() {
    final results = _runner.results;
    if (results.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              'Press Run to execute the requests.',
              style: TextStyle(color: Palette.textDim),
            ),
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: results.length,
      // Results are listed newest first, so a new one shifts every row down;
      // keyed rows keep their expanded state with their own result.
      findChildIndexCallback: (key) {
        final i = results.indexWhere((r) => ObjectKey(r) == key);
        return i < 0 ? null : results.length - 1 - i;
      },
      itemBuilder: (_, i) {
        // Newest first.
        final r = results[results.length - 1 - i];
        final res = r.response;
        final failedAsserts = r.assertions.where((a) => !a.pass).toList();
        final method = httpMethodHelp(r.request.method);
        final status = httpStatusHelp(res.error != null ? 0 : res.statusCode);
        return ExpansionTile(
          key: ObjectKey(r),
          dense: true,
          shape: const Border(),
          leading: HelpHover(
            r.pass
                ? 'Every test passed, or with no tests, the status was below '
                      '400.'
                : 'A test failed, the status was 4xx or 5xx, or no response '
                      'came back. Expand the row for details.',
            title: r.pass ? 'Passed' : 'Failed',
            child: Icon(
              r.pass ? Icons.check_circle : Icons.cancel,
              size: 17,
              color: r.pass ? Palette.get_ : Palette.delete,
            ),
          ),
          title: Row(
            children: [
              HelpHover(
                method.message,
                title: method.title,
                child: Text(
                  r.request.method,
                  style: TextStyle(
                    color: methodColor(r.request.method),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.request.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          subtitle: Align(
            alignment: Alignment.centerLeft,
            child: HelpHover(
              '${status.message} Shown as pass number • status • response '
              'time • tests passed.',
              title: status.title,
              example: 'pass 2 • 200 • 85 ms • 3/3 tests',
              child: Text(
                'pass ${r.iteration} • '
                '${res.error != null ? 'error' : res.statusCode} • '
                '${res.durationMs} ms'
                '${r.assertions.isNotEmpty ? ' • ${r.assertions.length - failedAsserts.length}/${r.assertions.length} tests' : ''}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: r.pass ? Palette.textDim : Palette.delete,
                ),
              ),
            ),
          ),
          children: [
            if (res.error != null)
              _detailLine(res.error!, Palette.delete)
            else ...[
              for (final a in r.assertions)
                _detailLine(
                  '${a.pass ? '✓' : '✗'} ${a.assertion.kind.label}'
                  '${a.assertion.kind.hasTarget ? ' ${a.assertion.target}' : ''}'
                  ' — ${a.message}',
                  a.pass ? Palette.get_ : Palette.delete,
                ),
              if (r.assertions.isEmpty)
                _detailLine(
                  'No tests on this request — judged by status code.',
                  Palette.textDim,
                ),
            ],
          ],
        );
      },
    );
  }

  Widget _detailLine(String text, Color color) => Padding(
    padding: const EdgeInsets.fromLTRB(52, 0, 16, 8),
    child: Align(
      alignment: Alignment.centerLeft,
      child: SelectableText(
        text,
        style: TextStyle(fontSize: 12, color: color, fontFamily: 'monospace'),
      ),
    ),
  );
}
