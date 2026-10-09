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
import 'adaptive.dart';
import 'app_menu.dart' show savePickedFile;
import 'help_tip.dart';

/// Concurrent load test of a collection: N virtual users run the requests
/// one by one (a user journey, with values passed between steps) or all at
/// once, with live throughput and p50/p95/p99 latency per request.
class LoadTestScreen extends StatefulWidget {
  const LoadTestScreen({
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
    _plan = [
      for (final r in widget.requests) LoadStep(r, extract: Map.of(r.captures)),
    ];
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }

  static const _resultsHelp =
      'Live totals for the run. A call passes when all its tests pass, or '
      'with no tests, when its status is below 400.';

  void _start() {
    _svc.start(
      plan: _plan,
      config: _config,
      vars: context.read<AppState>().varsFor(widget.collectionId),
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
          padding: EdgeInsets.all(isPhoneWidth(context) ? 10 : 14),
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

  Widget _card(
    String title,
    Widget child, {
    Widget? trailing,
    required String help,
    String? example,
  }) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
    decoration: BoxDecoration(
      color: Palette.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Palette.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The trailing part moves under the title when both do not fit.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            LabelWithHelp(
              title,
              help,
              example: example,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
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
    required String help,
    String? example,
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
          helperStyle: TextStyle(fontSize: 11, color: Palette.textDim),
          labelStyle: TextStyle(fontSize: 12, color: Palette.textDim),
          suffixIcon: HelpTip(help, title: label, example: example),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
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
      help:
          'How much traffic to send and how. Only load-test servers you own '
          'or have permission to test.',
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
                help:
                    'How many simulated users send requests at the same '
                    'time. Each one works through the request list on its '
                    'own.',
                example: '50',
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
                help:
                    'How many times each user goes through the request '
                    'list.',
                example: '5 users × 10 iterations = 50 rounds',
              ),
              _num(
                'Duration (s)',
                c.durationSec,
                (v) => c.durationSec = v,
                helper: c.untilStopped
                    ? 'Ignored (until stopped)'
                    : '0 = use iterations',
                help:
                    'Run for this many seconds instead of a set number of '
                    'iterations. 0 means use iterations.',
                example: '60  (one minute)',
              ),
              _num(
                'Ramp-up (s)',
                c.rampUpSec,
                (v) => c.rampUpSec = v,
                helper: 'Stagger user starts',
                help:
                    'Start users gradually over this many seconds instead of '
                    'all at once, so the server warms up. 0 starts everyone '
                    'together.',
                example: '10 s for 50 users = 5 new users a second',
              ),
              _num(
                'Think time (ms)',
                c.thinkTimeMs,
                (v) => c.thinkTimeMs = v,
                helper: 'Pause between steps',
                help:
                    'Pause after each request (after each round in All at '
                    'once mode), like a real person reading a page.',
                example: '500 ms',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'How each user works through the requests in a round.',
                title: 'Request order',
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: HelpHover(
                        'Each user sends the requests in order, like a real '
                        'user journey. Values extracted from one response '
                        'feed later requests.',
                        title: 'One by one',
                        example: 'Login → List orders → Pay',
                        child: Text('One by one'),
                      ),
                      icon: Icon(Icons.linear_scale, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: HelpHover(
                        'Each user fires every request at the same time each '
                        'round. Good for hammering independent endpoints.',
                        title: 'All at once',
                        child: Text('All at once'),
                      ),
                      icon: Icon(Icons.call_split, size: 16),
                    ),
                  ],
                  selected: {c.parallel},
                  onSelectionChanged: running
                      ? null
                      : (s) => setState(() => c.parallel = s.first),
                ),
              ),
              _switch(
                'Repeat until stopped',
                c.untilStopped,
                (v) => c.untilStopped = v,
                help:
                    'Keep going until you press Stop. Iterations and duration '
                    'are ignored.',
                example: 'Soak test overnight',
              ),
              if (!c.parallel)
                HelpHover(
                  'When a request fails, skip the rest of that user\'s round, '
                  'since later requests usually depend on it.',
                  title: 'Stop on first failure',
                  example: 'Login fails, so Pay is not sent',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: c.stopOnFailure,
                        onChanged: running
                            ? null
                            : (v) => setState(() => c.stopOnFailure = v),
                      ),
                      const Flexible(
                        child: Text(
                          'Stop iteration on first failure',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              HelpHover(
                running
                    ? 'Stop starting new requests. Calls already in flight '
                          'finish first.'
                    : 'Start the load test with these settings. Results '
                          'update live below.',
                title: running ? 'Stop' : 'Run',
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: running ? Palette.delete : Palette.accent,
                    foregroundColor: running ? Colors.white : Palette.onAccent,
                  ),
                  onPressed: running
                      ? (_svc.stopping ? null : _svc.stop)
                      : _start,
                  icon: Icon(running ? Icons.stop : Icons.play_arrow, size: 17),
                  label: Text(
                    running ? (_svc.stopping ? 'Stopping…' : 'Stop') : 'Run',
                  ),
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
                help:
                    'Write every call to a file on disk, so you can save the '
                    'full log as CSV or JSON when the run ends.',
                example: '#12  0.84s  u3 · i2  200  95 ms',
              ),
              if (c.recordLog) ...[
                LabelWithHelp(
                  'Save responses',
                  'Which response bodies the log keeps. Each is cut at 64 KB, '
                      'up to 256 MB per run.',
                  example: 'Failures only',
                  style: TextStyle(fontSize: 13, color: Palette.textDim),
                ),
                SegmentedButton<BodyCapture>(
                  segments: [
                    for (final b in BodyCapture.values)
                      ButtonSegment(
                        value: b,
                        label: HelpHover(
                          switch (b) {
                            BodyCapture.none =>
                              'Log status and timing only. Uses the least '
                                  'disk.',
                            BodyCapture.failures =>
                              'Keep the body of failed calls, so you can see '
                                  'the error messages.',
                            BodyCapture.all =>
                              'Keep every response body. Uses the most disk '
                                  'on long runs.',
                          },
                          title: b.label,
                          child: Text(b.label),
                        ),
                      ),
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
          Text(
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

  Widget _switch(
    String label,
    bool value,
    ValueChanged<bool> set, {
    required String help,
    String? example,
  }) => HelpHover(
    help,
    title: label,
    example: example,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(
          value: value,
          onChanged: _svc.running ? null : (v) => setState(() => set(v)),
        ),
        Flexible(child: Text(label, style: const TextStyle(fontSize: 13))),
      ],
    ),
  );

  Widget _steps() {
    final running = _svc.running;
    return _card(
      'Requests (${_plan.where((s) => s.enabled).length}/${_plan.length})',
      help:
          'The requests each user sends, with how many are ticked out of the '
          'total. Numbers show the order in One by one mode.',
      example: 'Requests (2/3)',
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
              HelpHover(
                _config.parallel
                    ? 'In All at once mode every request fires together, so '
                          'there is no order.'
                    : 'Each user sends the requests in this order.',
                title: _config.parallel ? 'No fixed order' : 'Step ${i + 1}',
                child: SizedBox(
                  width: 28,
                  child: Text(
                    _config.parallel ? '•' : '${i + 1}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Palette.textDim,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              HelpHover(
                'Ticked requests are sent in the load test. Untick one to '
                'leave it out of this run.',
                title: step.enabled ? 'Included' : 'Left out',
                child: Checkbox(
                  value: step.enabled,
                  onChanged: running
                      ? null
                      : (v) => setState(() => step.enabled = v ?? true),
                ),
              ),
              SizedBox(
                width: isPhoneWidth(context) ? 48 : 58,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: HelpHover(
                    httpMethodHelp(r.method).message,
                    title: httpMethodHelp(r.method).title,
                    child: Text(
                      r.method,
                      style: TextStyle(
                        color: methodColor(r.method),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Palette.textDim,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              if (step.extract.isNotEmpty)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: HelpHover(
                      'Variables this request extracts from its response. Later '
                      'requests in the same round can use them.',
                      title: 'Extracted values',
                      example: '{{token}}',
                      child: Text(
                        '→ ${step.extract.keys.map((k) => '{{$k}}').join(' ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Palette.accent,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
              IconButton(
                tooltip: open
                    ? 'Hide extract settings'
                    : 'Extract values for later requests',
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
                  suffixIcon: HelpTip(
                    'One per line as name = source (body.path, header.Name or '
                    'status). In One by one mode, later requests can use the '
                    'value as {{name}}.',
                    title: 'Extract',
                    example: 'token = body.data.token',
                  ),
                  suffixIconConstraints: BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
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
        help: _resultsHelp,
        Text(s.error!, style: TextStyle(color: Palette.delete)),
      );
    }
    if (s.total.count == 0 && !s.running) {
      return _card(
        'Results',
        help: _resultsHelp,
        Text(
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
      help: _resultsHelp,
      trailing: canSave ? _saveButton() : null,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HelpHover(
            'Time since the start, users sending right now, and rounds '
            'finished across all users.',
            title: s.running ? 'Running' : 'Finished',
            example: 'Running · 12.4s · 50 active users · 310 iterations done',
            child: Text(
              s.running
                  ? 'Running · ${secs.toStringAsFixed(1)}s · '
                        '${s.activeUsers} active users · '
                        '${s.iterationsDone} iterations done'
                  : 'Finished in ${secs.toStringAsFixed(1)}s · '
                        '${s.iterationsDone} iterations',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (s.logError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                s.logError!,
                style: TextStyle(fontSize: 12, color: Palette.delete),
              ),
            ),
          const SizedBox(height: 8),
          HelpHover(
            'How far the run has got, by planned calls or by time. It keeps '
            'moving without filling when the run has no fixed end.',
            title: 'Progress',
            child: LinearProgressIndicator(
              value: s.progress,
              color: Palette.accent,
              backgroundColor: Palette.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _tile(
                'Requests',
                _fmt(s.total.count),
                title: 'Requests',
                help: 'Total calls made so far in this run.',
              ),
              _tile(
                'Req / sec',
                s.requestsPerSecond.toStringAsFixed(1),
                title: 'Requests per second',
                help:
                    'Throughput: calls completed per second, averaged over '
                    'the run so far. Higher means the server keeps up.',
                example: '42.5',
              ),
              _tile(
                'Failed',
                '${_fmt(s.failed)} (${(s.errorRate * 100).toStringAsFixed(1)}%)',
                alert: s.failed > 0,
                title: 'Failed',
                help:
                    'Calls that failed a test, returned 4xx or 5xx with no '
                    'tests, or got no response, and their share of all calls.',
                example: '3 (1.5%)',
              ),
              _tile(
                'p50',
                '${s.total.percentile(50)} ms',
                title: 'p50 (median)',
                help:
                    'Half of the calls were faster than this. It is the '
                    'typical response time.',
                example: '120 ms',
              ),
              _tile(
                'p95',
                '${s.total.percentile(95)} ms',
                title: 'p95',
                help:
                    '95% of calls were faster than this, so only 1 call in 20 '
                    'took longer. A common target for speed goals.',
                example: '300 ms',
              ),
              _tile(
                'p99',
                '${s.total.percentile(99)} ms',
                title: 'p99',
                help:
                    '99% of calls were faster than this. It shows the rare '
                    'worst delays, 1 call in 100.',
                example: '800 ms',
              ),
              _tile(
                'Avg',
                '${s.total.meanMs.toStringAsFixed(1)} ms',
                title: 'Average',
                help:
                    'Total time divided by the number of calls. A few very '
                    'slow calls pull it up, so compare it with p50.',
              ),
              _tile(
                'Max',
                '${s.total.maxMs} ms',
                title: 'Max',
                help: 'The slowest single call in the run.',
              ),
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
    tooltip: 'Save the results as a report file',
    onSelected: _save,
    itemBuilder: (_) => [
      const PopupMenuItem(
        value: 'html',
        child: HelpHover(
          'One page with the summary, plus the call log when recorded. Opens '
          'in any browser and can be shared as one file.',
          title: 'HTML report',
          example: 'load-test-shop-api-2026-10-10.html',
          child: Text('HTML report (summary + log)'),
        ),
      ),
      if (_svc.log != null) ...[
        const PopupMenuItem(
          value: 'csv',
          child: HelpHover(
            'One line per call with time, user, status and duration, for '
            'spreadsheets.',
            title: 'CSV log',
            example: '12,0.84,3,2,Login,200,95',
            child: Text('CSV log (every call)'),
          ),
        ),
        const PopupMenuItem(
          value: 'json',
          child: HelpHover(
            'Every call plus any saved response bodies, for scripts and '
            'other tools.',
            title: 'JSON export',
            child: Text('JSON (every call + saved responses)'),
          ),
        ),
      ],
    ],
    child: Container(
      constraints: BoxConstraints(
        minHeight: isTouch(context) ? minTouchTarget : 0,
      ),
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
              : Icon(Icons.save_alt, size: 17, color: Palette.accent),
          const SizedBox(width: 6),
          Text(
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
      help:
          'Every call in order: number, seconds since the start, user and '
          'iteration, status and time. Click a row with a page icon to see '
          'its saved response.',
      example: '#12  0.84s  u3 · i2  200  95 ms',
      trailing: HelpHover(
        'Calls written to the log file. Only the newest 100 are listed '
        'here; save a report to get them all.',
        title: 'Calls logged',
        child: Text(
          '${_fmt(log.count)} calls logged'
          '${log.count > recent.length ? ' · newest ${recent.length} shown' : ''}',
          style: TextStyle(fontSize: 12, color: Palette.textDim),
        ),
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
                style: TextStyle(fontSize: 12, color: Palette.delete),
              ),
            ),
          LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in recent) _logRow(e, narrow: box.maxWidth < 520),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _logRow(LoadLogEntry e, {required bool narrow}) {
    const mono = TextStyle(
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final open = _openLog.contains(e.seq);
    final userIteration = HelpHover(
      'Which simulated user made this call (u) and which of its rounds it '
      'was in (i).',
      title: 'User and iteration',
      example: 'u3 · i2 = user 3, second round',
      child: Text(
        'u${e.vu} · i${e.iteration}',
        style: mono.copyWith(color: Palette.textDim),
      ),
    );
    final status = HelpHover(
      httpStatusHelp(e.status).message,
      title: httpStatusHelp(e.status).title,
      child: Text(
        e.status == 0 ? 'ERR' : '${e.status}',
        style: mono.copyWith(
          color: statusColor(e.status),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final name = Text(
      e.error ?? e.name,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: e.pass ? null : Palette.delete),
    );
    final bodyIcon = e.body == null
        ? null
        : Icon(
            open ? Icons.expand_less : Icons.description_outlined,
            size: 15,
            color: Palette.textDim,
          );
    // Phones: number, status and time on top, the request and when below.
    final Widget line = narrow
        ? Container(
            constraints: BoxConstraints(
              minHeight: isTouch(context) && e.body != null
                  ? minTouchTarget
                  : 0,
            ),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 56, child: Text('#${e.seq}', style: mono)),
                SizedBox(width: 40, child: status),
                SizedBox(
                  width: 64,
                  child: Text(
                    '${e.durationMs} ms',
                    textAlign: TextAlign.right,
                    style: mono,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      name,
                      Row(
                        children: [
                          Text(
                            '${(e.offsetMs / 1000).toStringAsFixed(2)}s · ',
                            style: mono.copyWith(color: Palette.textDim),
                          ),
                          Flexible(child: userIteration),
                        ],
                      ),
                    ],
                  ),
                ),
                ?bodyIcon,
              ],
            ),
          )
        : Container(
            constraints: BoxConstraints(
              minHeight: isTouch(context) && e.body != null
                  ? minTouchTarget
                  : 0,
            ),
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
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: userIteration,
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Align(alignment: Alignment.centerLeft, child: status),
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
                Expanded(child: name),
                ?bodyIcon,
              ],
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: e.body == null
              ? null
              : () => setState(
                  () => open ? _openLog.remove(e.seq) : _openLog.add(e.seq),
                ),
          child: line,
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

  Widget _tile(
    String label,
    String value, {
    bool alert = false,
    required String help,
    required String title,
    String? example,
  }) => HelpHover(
    help,
    title: title,
    example: example,
    child: _tileBox(label, value, alert: alert),
  );

  Widget _tileBox(String label, String value, {bool alert = false}) =>
      Container(
        width: 128,
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: Palette.surfaceAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: alert
                ? Palette.delete.withValues(alpha: 0.6)
                : Palette.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (alert) ...[
                  Icon(
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
                    style: TextStyle(fontSize: 11.5, color: Palette.textDim),
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
    Widget h(String t, String help) => HelpHover(
      help,
      title: t,
      child: Text(
        t,
        textAlign: TextAlign.right,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: Palette.textDim,
        ),
      ),
    );
    Widget n(String t, {Color? color}) => Text(
      t,
      textAlign: TextAlign.right,
      style: num.copyWith(color: color),
    );
    TableRow row(List<Widget> cells, {bool header = false}) => TableRow(
      decoration: header
          ? BoxDecoration(
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
        const LabelWithHelp(
          'Per request (latency in ms)',
          'The same numbers split by request, plus how often each status '
              'code came back. Latency means response time.',
          example: 'Login  50 calls  0 failed  p95 210',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, box) {
            // Eight columns need about 560 px; narrower screens scroll the
            // table sideways instead of squeezing the numbers.
            final table = Table(
              columnWidths: const {0: FlexColumnWidth(3)},
              defaultColumnWidth: const FlexColumnWidth(1),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                row([
                  Align(
                    alignment: Alignment.centerLeft,
                    child: h('Request', 'Each request in the load test plan.'),
                  ),
                  h('Calls', 'How many times this request was sent.'),
                  h('Failed', 'Calls of this request that did not pass.'),
                  h('Avg', 'Average response time in milliseconds.'),
                  h(
                    'p50',
                    'Half of this request\'s calls were faster than this.',
                  ),
                  h(
                    'p95',
                    '95% of this request\'s calls were faster than this.',
                  ),
                  h(
                    'p99',
                    '99% of this request\'s calls were faster than this.',
                  ),
                  h('Max', 'The slowest call of this request.'),
                ], header: true),
                for (final st in _svc.steps)
                  row([
                    Row(
                      children: [
                        HelpHover(
                          httpMethodHelp(st.request.method).message,
                          title: httpMethodHelp(st.request.method).title,
                          child: Text(
                            st.request.method,
                            style: TextStyle(
                              color: methodColor(st.request.method),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
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
            );
            if (box.maxWidth >= 560) return table;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: 560, child: table),
            );
          },
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
                    style: TextStyle(fontSize: 12, color: Palette.textDim),
                  ),
                  for (final e in st.statusCounts.entries)
                    HelpHover(
                      '${httpStatusHelp(e.key).message} This request got it '
                      '${_fmt(e.value)} times.',
                      title: httpStatusHelp(e.key).title,
                      child: Text(
                        '${e.key == 0 ? 'ERR' : e.key} ×${_fmt(e.value)}',
                        style: num.copyWith(
                          color: statusColor(e.key),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  for (final e in st.errors.entries)
                    HelpHover(
                      'A connection error and how many calls hit it. Check '
                      'the address, the network, or whether the server is '
                      'overloaded.',
                      title: 'Error',
                      child: Text(
                        '${e.key} (×${e.value})',
                        style: TextStyle(fontSize: 12, color: Palette.delete),
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

  Widget _legend(Color c, String label) => HelpHover(
    label == 'Passed'
        ? 'Calls in that second that passed their tests, or returned a '
              'status below 400.'
        : 'Calls in that second that failed a test, returned 4xx or 5xx, or '
              'got no response.',
    title: label,
    child: Row(
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
        Text(label, style: TextStyle(fontSize: 12, color: Palette.textDim)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final total = widget.perSecond;
    final errors = widget.errorsPerSecond;
    final hover = _hover != null && _hover! < total.length ? _hover : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            const LabelWithHelp(
              'Throughput (requests / second)',
              'Calls completed in each second of the run, with failures '
                  'stacked on top. Point at a bar to see its numbers.',
              example: 't = 12s · 48 requests · 2 failed',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _legend(Palette.accent, 'Passed'),
                const SizedBox(width: 12),
                _legend(Palette.delete, 'Failed'),
              ],
            ),
          ],
        ),
        SizedBox(
          height: 20,
          child: hover == null
              ? null
              : Text(
                  't = ${widget.firstSecond + hover}s · ${total[hover]} requests'
                  '${errors[hover] > 0 ? ' · ${errors[hover]} failed' : ''}',
                  style: TextStyle(fontSize: 12, color: Palette.textDim),
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
        style: TextStyle(fontSize: 10.5, color: Palette.textDim),
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
