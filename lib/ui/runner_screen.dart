import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/runner.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Collection / request runner: fixed iterations or recurring interval runs,
/// with live results, assertion outcomes and latency statistics.
class RunnerScreen extends StatefulWidget {
  const RunnerScreen({super.key, required this.title, required this.requests});

  final String title;
  final List<RequestModel> requests;

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
      vars: context.read<AppState>().activeVars,
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
        title: Text('Run • ${widget.title}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: AnimatedBuilder(
        animation: _runner,
        builder: (context, _) => Column(
          children: [
            _configBar(),
            if (_showData) _dataPanel(),
            const Divider(height: 1, color: Palette.border),
            if (_runner.results.isNotEmpty) _summaryBar(),
            Expanded(child: _resultsList()),
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
          Text('${widget.requests.length} request(s)',
              style: const TextStyle(color: Palette.textDim, fontSize: 12.5)),
          if (!_recurring && _dataRows == null)
            _numField('Iterations', _iterCtrl, enabled: !running),
          _numField('Delay between (ms)', _delayCtrl, enabled: !running),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: _recurring,
                onChanged:
                    running ? null : (v) => setState(() => _recurring = v),
              ),
              const Text('Recurring', style: TextStyle(fontSize: 13)),
            ],
          ),
          if (_recurring)
            _numField('Every (s)', _intervalCtrl, enabled: !running),
          TextButton.icon(
            onPressed: () => setState(() => _showData = !_showData),
            icon: Icon(
                _showData ? Icons.expand_less : Icons.table_rows_outlined,
                size: 16),
            label: Text(_dataRows == null
                ? 'Data'
                : 'Data (${_dataRows!.length} rows)'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: running ? Palette.delete : Palette.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: running ? _runner.stop : _start,
            icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 17),
            label: Text(running ? 'Stop' : 'Run'),
          ),
          if (running && _runner.nextPassAt != null)
            Text(
              'pass ${_runner.currentIteration} done — next pass shortly…',
              style: const TextStyle(color: Palette.textDim, fontSize: 12),
            )
          else if (running)
            Text('running pass ${_runner.currentIteration}…',
                style: const TextStyle(color: Palette.textDim, fontSize: 12)),
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
              hintText: 'JSON array — one variable set per iteration:\n'
                  '[{"userId": "1"}, {"userId": "2"}, {"userId": "3"}]\n'
                  'Use them in requests as {{userId}}.',
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
                color: hasText && rows == null
                    ? Palette.delete
                    : Palette.textDim),
          ),
        ],
      ),
    );
  }

  Widget _numField(String label, TextEditingController ctrl,
      {required bool enabled}) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: ctrl,
        enabled: enabled,
        keyboardType: TextInputType.number,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
            labelText: label,
            labelStyle:
                const TextStyle(fontSize: 12, color: Palette.textDim)),
      ),
    );
  }

  Widget _summaryBar() {
    final r = _runner;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: Palette.surface,
      child: Row(
        children: [
          _stat('Passed', '${r.passed}', Palette.get_),
          _stat('Failed', '${r.failed}',
              r.failed == 0 ? Palette.textDim : Palette.delete),
          _stat('Avg', '${r.avgMs} ms', Palette.textDim),
          _stat('Min', '${r.minMs} ms', Palette.textDim),
          _stat('Max', '${r.maxMs} ms', Palette.textDim),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) => Padding(
        padding: const EdgeInsets.only(right: 22),
        child: Row(
          children: [
            Text('$label ',
                style:
                    const TextStyle(fontSize: 12, color: Palette.textDim)),
            Text(value,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      );

  Widget _resultsList() {
    final results = _runner.results;
    if (results.isEmpty) {
      return const Center(
        child: Text('Press Run to execute the requests.',
            style: TextStyle(color: Palette.textDim)),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) {
        // Newest first.
        final r = results[results.length - 1 - i];
        final res = r.response;
        final failedAsserts = r.assertions.where((a) => !a.pass).toList();
        return ExpansionTile(
          dense: true,
          shape: const Border(),
          leading: Icon(r.pass ? Icons.check_circle : Icons.cancel,
              size: 17, color: r.pass ? Palette.get_ : Palette.delete),
          title: Row(
            children: [
              Text(r.request.method,
                  style: TextStyle(
                      color: methodColor(r.request.method),
                      fontSize: 11,
                      fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(r.request.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
          subtitle: Text(
            'pass ${r.iteration} • '
            '${res.error != null ? 'error' : res.statusCode} • '
            '${res.durationMs} ms'
            '${r.assertions.isNotEmpty ? ' • ${r.assertions.length - failedAsserts.length}/${r.assertions.length} tests' : ''}',
            style: TextStyle(
                fontSize: 11.5,
                color: r.pass ? Palette.textDim : Palette.delete),
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
                    a.pass ? Palette.get_ : Palette.delete),
              if (r.assertions.isEmpty)
                _detailLine(
                    'No tests on this request — judged by status code.',
                    Palette.textDim),
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
          child: SelectableText(text,
              style: TextStyle(
                  fontSize: 12, color: color, fontFamily: 'monospace')),
        ),
      );
}
