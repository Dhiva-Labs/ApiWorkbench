import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/load_report.dart';
import '../services/load_test.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'app_menu.dart' show savePickedFile;

/// Concurrent load test of a collection: N virtual users run the requests
/// one by one (a user journey, with values passed between steps) or all at
/// once, with live throughput and p50/p95/p99 latency per request.
class LoadTestScreen extends StatefulWidget {
  const LoadTestScreen({
    super.key,
    required this.title,
    required this.requests,
  });

  final String title;
  final List<RequestModel> requests;

  @override
  State<LoadTestScreen> createState() => _LoadTestScreenState();
}

class _LoadTestScreenState extends State<LoadTestScreen> {
  late final LoadTestService _svc;
  late final List<LoadStep> _plan;
  final _config = LoadTestConfig();
  final Set<int> _openSteps = {};
  final Set<int> _openLog = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _svc = LoadTestService(context.read<AppState>().settings);
    _plan = [for (final r in widget.requests) LoadStep(r)];
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }

  void _start() {
    _svc.start(
      plan: _plan,
      config: _config,
      vars: context.read<AppState>().activeVars,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Load test • ${widget.title}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: AnimatedBuilder(
        animation: _svc,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _profile(),
            const SizedBox(height: 14),
            _steps(),
            const SizedBox(height: 14),
            _results(),
            if (_svc.log != null && _svc.log!.count > 0) ...[
              const SizedBox(height: 14),
              _logCard(),
            ],
          ],
        ),
      ),
    );
  }

  // ---- configuration ------------------------------------------------------

  Widget _card(String title, Widget child, {Widget? trailing}) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
    decoration: BoxDecoration(
      color: Palette.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Palette.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _num(
    String label,
    int value,
    ValueChanged<int> set, {
    String? helper,
    int maxValue = 100000,
  }) {
    return SizedBox(
      width: 150,
      child: TextFormField(
        initialValue: '$value',
        enabled: !_svc.running,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperStyle: const TextStyle(fontSize: 11, color: Palette.textDim),
          labelStyle: const TextStyle(fontSize: 12, color: Palette.textDim),
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null) setState(() => set(n.clamp(0, maxValue)));
        },
      ),
    );
  }

  Widget _profile() {
    final running = _svc.running;
    final c = _config;
    return _card(
      'Load profile',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _num(
                'Parallel users',
                c.virtualUsers,
                (v) => c.virtualUsers = max(1, v),
                helper:
                    'In flight at once (max ${LoadTestConfig.maxVirtualUsers})',
                maxValue: LoadTestConfig.maxVirtualUsers,
              ),
              _num(
                'Iterations / user',
                c.iterations,
                (v) => c.iterations = max(1, v),
                helper: c.untilStopped
                    ? 'Ignored (until stopped)'
                    : c.durationSec > 0
                    ? 'Ignored (duration set)'
                    : 'Total ${c.virtualUsers * c.iterations} rounds',
              ),
              _num(
                'Duration (s)',
                c.durationSec,
                (v) => c.durationSec = v,
                helper: c.untilStopped
                    ? 'Ignored (until stopped)'
                    : '0 = use iterations',
              ),
              _num(
                'Ramp-up (s)',
                c.rampUpSec,
                (v) => c.rampUpSec = v,
                helper: 'Stagger user starts',
              ),
              _num(
                'Think time (ms)',
                c.thinkTimeMs,
                (v) => c.thinkTimeMs = v,
                helper: 'Pause between steps',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('One by one'),
                    icon: Icon(Icons.linear_scale, size: 16),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('All at once'),
                    icon: Icon(Icons.call_split, size: 16),
                  ),
                ],
                selected: {c.parallel},
                onSelectionChanged: running
                    ? null
                    : (s) => setState(() => c.parallel = s.first),
              ),
              _switch(
                'Repeat until stopped',
                c.untilStopped,
                (v) => c.untilStopped = v,
              ),
              if (!c.parallel)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: c.stopOnFailure,
                      onChanged: running
                          ? null
                          : (v) => setState(() => c.stopOnFailure = v),
                    ),
                    const Text(
                      'Stop iteration on first failure',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: running ? Palette.delete : Palette.accent,
                  foregroundColor: Colors.white,
                ),
                onPressed: running
                    ? (_svc.stopping ? null : _svc.stop)
                    : _start,
                icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 17),
                label: Text(
                  running ? (_svc.stopping ? 'Stopping…' : 'Stop') : 'Run',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _switch(
                'Record request log',
                c.recordLog,
                (v) => c.recordLog = v,
              ),
              if (c.recordLog) ...[
                const Text(
                  'Save responses',
                  style: TextStyle(fontSize: 13, color: Palette.textDim),
                ),
                SegmentedButton<BodyCapture>(
                  segments: [
                    for (final b in BodyCapture.values)
                      ButtonSegment(value: b, label: Text(b.label)),
                  ],
                  selected: {c.bodies},
                  onSelectionChanged: running
                      ? null
                      : (v) => setState(() => c.bodies = v.first),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Each virtual user gets the active environment plus {{vu}} and '
            '{{iteration}}. In "One by one" mode, values extracted from a '
            'response (e.g. token = body.data.token) are available to later '
            'requests as {{token}}. Pass/fail uses each request\'s Tests, or '
            'status < 400 when it has none. With the request log on, every '
            'call is written to disk (not kept in memory) and can be saved '
            'as a report when the run ends. Only load-test servers you own.',
            style: TextStyle(fontSize: 12, color: Palette.textDim, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> set) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Switch(
        value: value,
        onChanged: _svc.running ? null : (v) => setState(() => set(v)),
      ),
      Text(label, style: const TextStyle(fontSize: 13)),
    ],
  );

  Widget _steps() {
    final running = _svc.running;
    return _card(
      'Requests (${_plan.where((s) => s.enabled).length}/${_plan.length})',
      Column(
        children: [for (var i = 0; i < _plan.length; i++) _stepRow(i, running)],
      ),
    );
  }

  static String _extractText(Map<String, String> m) =>
      m.entries.map((e) => '${e.key} = ${e.value}').join('\n');

  static Map<String, String> _parseExtract(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      if (k.isNotEmpty) out[k] = line.substring(i + 1).trim();
    }
    return out;
  }

  Widget _stepRow(int i, bool running) {
    final step = _plan[i];
    final r = step.request;
    final open = _openSteps.contains(i);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Palette.surfaceAlt.withValues(alpha: step.enabled ? 1 : 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  _config.parallel ? '•' : '${i + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Palette.textDim,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Checkbox(
                value: step.enabled,
                onChanged: running
                    ? null
                    : (v) => setState(() => step.enabled = v ?? true),
              ),
              SizedBox(
                width: 58,
                child: Text(
                  r.method,
                  style: TextStyle(
                    color: methodColor(r.method),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    Text(
                      r.url,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Palette.textDim,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              if (step.extract.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '→ ${step.extract.keys.map((k) => '{{$k}}').join(' ')}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Palette.accent,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              IconButton(
                tooltip: open ? 'Hide' : 'Extract values for later requests',
                icon: Icon(
                  open ? Icons.expand_less : Icons.output_outlined,
                  size: 18,
                ),
                onPressed: () => setState(
                  () => open ? _openSteps.remove(i) : _openSteps.add(i),
                ),
              ),
            ],
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 12, 10),
              child: TextFormField(
                initialValue: _extractText(step.extract),
                enabled: !running,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                decoration: const InputDecoration(
                  labelText: 'Extract (one per line)',
                  hintText:
                      'token = body.data.token\nid = data.items[0].id\n'
                      'etag = header.etag',
                  alignLabelWithHint: true,
                ),
                onChanged: (v) =>
                    setState(() => step.extract = _parseExtract(v)),
              ),
            ),
        ],
      ),
    );
  }

  // ---- results ------------------------------------------------------------

  Widget _results() {
    final s = _svc;
    if (s.error != null) {
      return _card(
        'Results',
        Text(s.error!, style: const TextStyle(color: Palette.delete)),
      );
    }
    if (s.total.count == 0 && !s.running) {
      return _card(
        'Results',
        const Text(
          'Press Run to start. Throughput, error rate and latency '
          'percentiles appear here live.',
          style: TextStyle(color: Palette.textDim),
        ),
      );
    }
    final secs = s.elapsedMs / 1000;
    final canSave = !s.running && s.total.count > 0;
    return _card(
      'Results',
      trailing: canSave ? _saveButton() : null,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.running
                ? 'Running · ${secs.toStringAsFixed(1)}s · '
                      '${s.activeUsers} active users · '
                      '${s.iterationsDone} iterations done'
                : 'Finished in ${secs.toStringAsFixed(1)}s · '
                      '${s.iterationsDone} iterations',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (s.logError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                s.logError!,
                style: const TextStyle(fontSize: 12, color: Palette.delete),
              ),
            ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: s.progress,
            color: Palette.accent,
            backgroundColor: Palette.border,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _tile('Requests', _fmt(s.total.count)),
              _tile('Req / sec', s.requestsPerSecond.toStringAsFixed(1)),
              _tile(
                'Failed',
                '${_fmt(s.failed)} (${(s.errorRate * 100).toStringAsFixed(1)}%)',
                alert: s.failed > 0,
              ),
              _tile('p50', '${s.total.percentile(50)} ms'),
              _tile('p95', '${s.total.percentile(95)} ms'),
              _tile('p99', '${s.total.percentile(99)} ms'),
              _tile('Avg', '${s.total.meanMs.toStringAsFixed(1)} ms'),
              _tile('Max', '${s.total.maxMs} ms'),
            ],
          ),
          if (s.perSecond.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ThroughputChart(
              perSecond: List.of(s.perSecond),
              errorsPerSecond: List.of(s.errorsPerSecond),
              firstSecond: s.timelineStart,
            ),
          ],
          const SizedBox(height: 16),
          _stepTable(),
        ],
      ),
    );
  }

  // ---- log & report -------------------------------------------------------

  String get _slug {
    final t = widget.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final d = (_svc.startedAt ?? DateTime.now()).toIso8601String();
    final stamp = d.substring(0, 19).replaceAll(RegExp('[:T]'), '-');
    return 'load-test-${t.isEmpty ? 'run' : (t.length > 40 ? t.substring(0, 40) : t)}-$stamp';
  }

  Widget _saveButton() => PopupMenuButton<String>(
    enabled: !_saving,
    tooltip: 'Save report',
    onSelected: _save,
    itemBuilder: (_) => [
      const PopupMenuItem(
        value: 'html',
        child: Text('HTML report (summary + log)'),
      ),
      if (_svc.log != null) ...[
        const PopupMenuItem(value: 'csv', child: Text('CSV log (every call)')),
        const PopupMenuItem(
          value: 'json',
          child: Text('JSON (every call + saved responses)'),
        ),
      ],
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt, size: 17, color: Palette.accent),
          const SizedBox(width: 6),
          const Text(
            'Save report',
            style: TextStyle(color: Palette.accent, fontSize: 13),
          ),
        ],
      ),
    ),
  );

  Future<void> _save(String format) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final text = switch (format) {
        'csv' => await buildLoadCsv(_svc),
        'json' => await buildLoadJson(_svc, widget.title),
        _ => await buildLoadHtml(_svc, widget.title),
      };
      final path = await savePickedFile(
        dialogTitle: 'Save load test report',
        fileName: '$_slug.$format',
        extensions: [format],
        bytes: utf8.encode(text),
      );
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $path')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _logCard() {
    final log = _svc.log!;
    final recent = log.recent.reversed.take(100).toList();
    return _card(
      'Request log',
      trailing: Text(
        '${_fmt(log.count)} calls logged'
        '${log.count > recent.length ? ' · newest ${recent.length} shown' : ''}',
        style: const TextStyle(fontSize: 12, color: Palette.textDim),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (log.bodiesDropped > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${_fmt(log.bodiesDropped)} responses not saved: the run hit '
                'the 256 MB limit for saved bodies.',
                style: const TextStyle(fontSize: 12, color: Palette.delete),
              ),
            ),
          for (final e in recent) _logRow(e),
        ],
      ),
    );
  }

  Widget _logRow(LoadLogEntry e) {
    const mono = TextStyle(
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final open = _openLog.contains(e.seq);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: e.body == null
              ? null
              : () => setState(
                  () => open ? _openLog.remove(e.seq) : _openLog.add(e.seq),
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(width: 64, child: Text('#${e.seq}', style: mono)),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${(e.offsetMs / 1000).toStringAsFixed(2)}s',
                    style: mono.copyWith(color: Palette.textDim),
                  ),
                ),
                SizedBox(
                  width: 92,
                  child: Text(
                    'u${e.vu} · i${e.iteration}',
                    style: mono.copyWith(color: Palette.textDim),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    e.status == 0 ? 'ERR' : '${e.status}',
                    style: mono.copyWith(
                      color: statusColor(e.status),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${e.durationMs} ms',
                    textAlign: TextAlign.right,
                    style: mono,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    e.error ?? e.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: e.pass ? null : Palette.delete,
                    ),
                  ),
                ),
                if (e.body != null)
                  Icon(
                    open ? Icons.expand_less : Icons.description_outlined,
                    size: 15,
                    color: Palette.textDim,
                  ),
              ],
            ),
          ),
        ),
        if (open)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Palette.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                '${e.body}${e.bodyTruncated ? '\n… (first 64 KB)' : ''}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _tile(String label, String value, {bool alert = false}) => Container(
    width: 128,
    padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
    decoration: BoxDecoration(
      color: Palette.surfaceAlt,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: alert ? Palette.delete.withValues(alpha: 0.6) : Palette.border,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (alert) ...[
              const Icon(
                Icons.warning_amber_rounded,
                size: 13,
                color: Palette.delete,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Palette.textDim),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  Widget _stepTable() {
    const num = TextStyle(
      fontSize: 12.5,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    Widget h(String t) => Text(
      t,
      textAlign: TextAlign.right,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: Palette.textDim,
      ),
    );
    Widget n(String t, {Color? color}) => Text(
      t,
      textAlign: TextAlign.right,
      style: num.copyWith(color: color),
    );
    TableRow row(List<Widget> cells, {bool header = false}) => TableRow(
      decoration: header
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: Palette.border)),
            )
          : null,
      children: [
        for (final c in cells)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
            child: c,
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Per request (latency in ms)',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Table(
          columnWidths: const {0: FlexColumnWidth(3)},
          defaultColumnWidth: const FlexColumnWidth(1),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            row([
              Align(alignment: Alignment.centerLeft, child: h('Request')),
              h('Calls'),
              h('Failed'),
              h('Avg'),
              h('p50'),
              h('p95'),
              h('p99'),
              h('Max'),
            ], header: true),
            for (final st in _svc.steps)
              row([
                Row(
                  children: [
                    Text(
                      st.request.method,
                      style: TextStyle(
                        color: methodColor(st.request.method),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        st.request.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
                n(_fmt(st.count)),
                n(
                  _fmt(st.failed),
                  color: st.failed > 0 ? Palette.delete : null,
                ),
                n(st.hist.meanMs.toStringAsFixed(1)),
                n('${st.hist.percentile(50)}'),
                n('${st.hist.percentile(95)}'),
                n('${st.hist.percentile(99)}'),
                n('${st.hist.maxMs}'),
              ]),
          ],
        ),
        for (final st in _svc.steps)
          if (st.statusCounts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  Text(
                    st.request.name,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Palette.textDim,
                    ),
                  ),
                  for (final e in st.statusCounts.entries)
                    Text(
                      '${e.key == 0 ? 'ERR' : e.key} ×${_fmt(e.value)}',
                      style: num.copyWith(
                        color: statusColor(e.key),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  for (final e in st.errors.entries)
                    Text(
                      '${e.key} (×${e.value})',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Palette.delete,
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Requests per second, failures stacked on top in the error colour, with a
/// hover readout. One y-axis.
class _ThroughputChart extends StatefulWidget {
  const _ThroughputChart({
    required this.perSecond,
    required this.errorsPerSecond,
    required this.firstSecond,
  });

  final List<int> perSecond;
  final List<int> errorsPerSecond;
  final int firstSecond;

  @override
  State<_ThroughputChart> createState() => _ThroughputChartState();
}

class _ThroughputChartState extends State<_ThroughputChart> {
  int? _hover;

  Widget _legend(Color c, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 12, color: Palette.textDim)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final total = widget.perSecond;
    final errors = widget.errorsPerSecond;
    final hover = _hover != null && _hover! < total.length ? _hover : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Throughput (requests / second)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const Spacer(),
            _legend(Palette.accent, 'Passed'),
            const SizedBox(width: 12),
            _legend(Palette.delete, 'Failed'),
          ],
        ),
        SizedBox(
          height: 20,
          child: hover == null
              ? null
              : Text(
                  't = ${widget.firstSecond + hover}s · ${total[hover]} requests'
                  '${errors[hover] > 0 ? ' · ${errors[hover]} failed' : ''}',
                  style: const TextStyle(fontSize: 12, color: Palette.textDim),
                ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            void track(Offset p) {
              final i = (p.dx / (c.maxWidth / max(total.length, 1))).floor();
              setState(() => _hover = i >= 0 && i < total.length ? i : null);
            }

            return MouseRegion(
              onHover: (e) => track(e.localPosition),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                onPanDown: (d) => track(d.localPosition),
                child: CustomPaint(
                  size: Size(c.maxWidth, 110),
                  painter: _BarsPainter(total, errors, hover),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.total, this.errors, this.hover);

  final List<int> total;
  final List<int> errors;
  final int? hover;

  @override
  void paint(Canvas canvas, Size size) {
    final peak = total.fold<int>(1, max);
    const top = 14.0;
    final h = size.height - top;
    final grid = Paint()
      ..color = Palette.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      grid,
    );
    canvas.drawLine(const Offset(0, top), Offset(size.width, top), grid);
    final tp = TextPainter(
      text: TextSpan(
        text: '$peak/s',
        style: const TextStyle(fontSize: 10.5, color: Palette.textDim),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width, 0));

    final slot = size.width / max(total.length, 1);
    final barW = max(1.0, min(14.0, slot - 2));
    for (var i = 0; i < total.length; i++) {
      if (total[i] == 0) continue;
      final x = i * slot + (slot - barW) / 2;
      final fullH = h * total[i] / peak;
      final errH = h * errors[i] / peak;
      final okH = fullH - errH;
      final dim = hover != null && hover != i;
      final r = Radius.circular(min(4, barW / 2));
      if (okH > 0) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, size.height - okH, barW, okH),
            topLeft: errH > 0 ? Radius.zero : r,
            topRight: errH > 0 ? Radius.zero : r,
          ),
          Paint()..color = Palette.accent.withValues(alpha: dim ? 0.45 : 1),
        );
      }
      if (errH > 0) {
        final gap = okH > 0 ? 2.0 : 0.0; // surface gap between segments
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(x, size.height - fullH, barW, max(1, errH - gap)),
            topLeft: r,
            topRight: r,
          ),
          Paint()..color = Palette.delete.withValues(alpha: dim ? 0.45 : 1),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => true;
}
