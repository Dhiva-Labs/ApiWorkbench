import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/data_files.dart';
import '../services/runner.dart';
import '../services/scripting/script_engine.dart';
import '../services/var_scopes.dart';
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
    this.engine,
  });

  final String title;
  final List<RequestModel> requests;

  /// Collection the requests come from, for its variables.
  final String? collectionId;

  /// Runs the scripts; the app's engine when null.
  final ScriptEngine? engine;

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

  /// Keep what scripts and captures change (Postman's "Keep variable
  /// values"); off, the run works on copies that are thrown away.
  bool _keepValues = true;

  /// A data file chosen from disk; it replaces the pasted text.
  DataFile? _file;
  String? _fileName;
  String? _fileError;

  /// The rows the run will use, from the file or the pasted text.
  DataFile? _data;
  String? _dataError;

  /// Largest data file read, to keep the preview and the run responsive.
  static const _maxFileBytes = 25 * 1024 * 1024;

  List<Map<String, String>>? get _dataRows => _data?.rows;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _runner = RunnerService(state.http, engine: widget.engine ?? state.scripts);
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

  /// Re-reads the rows after the pasted text or the chosen file changed.
  void _readData() {
    if (_file != null) {
      _data = _file;
      _dataError = null;
      return;
    }
    final text = _dataCtrl.text;
    if (text.trim().isEmpty) {
      _data = null;
      _dataError = null;
      return;
    }
    try {
      _data = readDataFile(text);
      _dataError = null;
    } on FormatException catch (e) {
      _data = null;
      _dataError = e.message;
    }
  }

  Future<void> _loadFile() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a CSV or JSON data file',
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'json', 'txt'],
      withData: true,
    );
    final f = picked?.files.firstOrNull;
    if (f == null || !mounted) return;
    String? error;
    DataFile? file;
    try {
      if (f.size > _maxFileBytes) {
        throw FormatException(
          'The file is ${(f.size / (1024 * 1024)).toStringAsFixed(1)} MB; '
          'data files can be up to ${_maxFileBytes ~/ (1024 * 1024)} MB.',
        );
      }
      final bytes =
          f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        throw const FormatException('The file could not be read.');
      }
      file = readDataFile(decodeDataBytes(bytes), fileName: f.name);
    } on FormatException catch (e) {
      error = '${f.name}: ${e.message}';
    } on FileSystemException catch (e) {
      error = '${f.name}: ${e.message}';
    }
    if (!mounted) return;
    setState(() {
      _fileError = error;
      if (file != null) {
        _file = file;
        _fileName = f.name;
        _readData();
      }
    });
  }

  void _clearFile() => setState(() {
    _file = null;
    _fileName = null;
    _fileError = null;
    _readData();
  });

  /// Scopes over copies of the variable lists, so the run's changes are
  /// dropped when it ends.
  VarScopes _isolatedScopes(AppState state) {
    final live = state.scopesFor(widget.collectionId);
    List<KV>? copy(List<KV>? l) =>
        l == null ? null : [for (final v in l) v.clone()];
    return VarScopes(
      globals: copy(live.globals),
      collection: copy(live.collection),
      environment: copy(live.environment),
      session: {...live.session},
    );
  }

  void _start() {
    final state = context.read<AppState>();
    final iterations = (int.tryParse(_iterCtrl.text) ?? 1).clamp(1, 100);
    final delayMs = (int.tryParse(_delayCtrl.text) ?? 0).clamp(0, 60000);
    final intervalS = (int.tryParse(_intervalCtrl.text) ?? 30).clamp(5, 3600);
    _iterCtrl.text = '$iterations';
    _delayCtrl.text = '$delayMs';
    _intervalCtrl.text = '$intervalS';
    final keep = _keepValues;
    _runner.start(
      requests: widget.requests,
      scopes: keep
          ? state.scopesFor(widget.collectionId)
          : _isolatedScopes(state),
      collection: state.collectionById(widget.collectionId),
      iterations: iterations,
      delayBetween: Duration(milliseconds: delayMs),
      repeatEvery: _recurring ? Duration(seconds: intervalS) : null,
      dataRows: _dataRows,
      // Saves variable changes and puts script output in the console; a run
      // on copies only logs.
      onResult: keep
          ? (result, scopes) => state.absorb(scopes, result)
          : (result, _) => state.console.addLines(result.logs),
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
            'Run once per row of test data, from a CSV or JSON file or '
            'pasted text. Each row\'s values become {{variables}} for that '
            'pass.',
            title: 'Test data',
            example: 'users.csv with the columns userId,name',
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
            'On: variables that scripts and captures set during the run are '
            'saved to the environment, collection and globals, like '
            'Postman. Off: the run works on copies and every change is '
            'thrown away when it ends.',
            title: 'Keep variable values',
            example: 'Run a login request, then use its token afterwards',
            child: InkWell(
              onTap: running
                  ? null
                  : () => setState(() => _keepValues = !_keepValues),
              borderRadius: BorderRadius.circular(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _keepValues,
                    onChanged: running
                        ? null
                        : (v) => setState(() => _keepValues = v ?? true),
                  ),
                  const Flexible(
                    child: Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Text(
                        'Keep variable values',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
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

  /// Data-driven runs: one row per iteration, merged over the active
  /// environment's variables. The rows come from a CSV or JSON file, or from
  /// text pasted in either format.
  Widget _dataPanel() {
    final data = _data;
    final hasFile = _file != null;
    final problem = _fileError ?? (hasFile ? null : _dataError);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HelpHover(
                'Pick a CSV file (a header row, then one row per iteration; '
                'quote values that contain commas) or a JSON file with an '
                'array of objects. It replaces the pasted text.',
                title: 'Load data file',
                example: 'users.csv:  userId,name  /  1,Ada  /  2,Linus',
                child: OutlinedButton.icon(
                  onPressed: _runner.running ? null : _loadFile,
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('Load data file'),
                ),
              ),
              if (hasFile)
                HelpHover(
                  'Stop using this file. The pasted text below (if any) is '
                  'used again.',
                  title: 'Remove the data file',
                  child: InputChip(
                    avatar: const Icon(Icons.description_outlined, size: 16),
                    label: Text(
                      _fileName ?? 'data file',
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: _runner.running ? null : _clearFile,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _dataCtrl,
            enabled: !_runner.running && !hasFile,
            maxLines: 5,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: InputDecoration(
              hintText: hasFile
                  ? 'Using $_fileName. Remove the file to paste data instead.'
                  : 'Or paste JSON or CSV — one variable set per iteration:\n'
                        '[{"userId": "1"}, {"userId": "2"}]\n'
                        'userId,name\n1,Ada\n2,Linus\n'
                        'Use the columns in requests as {{userId}}.',
              suffixIcon: const HelpTip(
                'A JSON list of objects, or CSV with a header row. Each row is '
                'one pass, and its columns override same-named variables; '
                'without Recurring, the run does one pass per row.',
                title: 'Data rows',
                example: '[{"userId": "1"}, {"userId": "2"}]',
              ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
            onChanged: (_) => setState(_readData),
          ),
          const SizedBox(height: 4),
          Text(
            problem ??
                (data != null
                    ? '${data.format.label}: ${data.rows.length} rows, '
                          '${data.columns.length} columns — '
                          '${_recurring ? 'cycled across recurring passes' : 'the run will do ${data.rows.length} iterations'}.'
                    : 'Leave empty to run without per-iteration data.'),
            style: TextStyle(
              fontSize: 11.5,
              color: problem != null ? Palette.delete : Palette.textDim,
            ),
          ),
          if (data != null) ...[const SizedBox(height: 8), _DataPreview(data)],
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
        final failedChecks =
            r.assertions.where((a) => !a.pass).length +
            r.scriptTests.where((t) => !t.pass).length;
        final checks = r.assertions.length + r.scriptTests.length;
        final method = httpMethodHelp(r.request.method);
        final status = httpStatusHelp(res.error != null ? 0 : res.statusCode);
        final scriptError = r.scriptError;
        return ExpansionTile(
          key: ObjectKey(r),
          dense: true,
          shape: const Border(),
          leading: HelpHover(
            r.skipped
                ? 'A pre-request script skipped this request.'
                : r.pass
                ? 'Every test passed, or with no tests, the status was below '
                      '400.'
                : 'A test or script failed, the status was 4xx or 5xx, or no '
                      'response came back. Expand the row for details.',
            title: r.skipped
                ? 'Skipped'
                : r.pass
                ? 'Passed'
                : 'Failed',
            child: Icon(
              r.skipped
                  ? Icons.skip_next
                  : r.pass
                  ? Icons.check_circle
                  : Icons.cancel,
              size: 17,
              color: r.skipped
                  ? Palette.textDim
                  : r.pass
                  ? Palette.get_
                  : Palette.delete,
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
                '${r.skipped
                    ? 'skipped'
                    : res.error != null
                    ? 'error'
                    : res.statusCode} • '
                '${res.durationMs} ms'
                '${checks > 0 ? ' • ${checks - failedChecks}/$checks tests' : ''}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: r.pass ? Palette.textDim : Palette.delete,
                ),
              ),
            ),
          ),
          children: [
            if (r.skipped)
              _detailLine('Skipped by a pre-request script.', Palette.textDim)
            else if (res.error != null)
              _detailLine(res.error!, Palette.delete),
            // A failed pre-request script already shows as the error above.
            if (scriptError != null && !(res.error ?? '').contains(scriptError))
              _detailLine('Script error: $scriptError', Palette.delete),
            if (res.error == null)
              for (final a in r.assertions)
                _detailLine(
                  '${a.pass ? '✓' : '✗'} ${a.assertion.kind.label}'
                  '${a.assertion.kind.hasTarget ? ' ${a.assertion.target}' : ''}'
                  ' — ${a.message}',
                  a.pass ? Palette.get_ : Palette.delete,
                ),
            for (final t in r.scriptTests)
              _detailLine(
                '${t.pass ? '✓' : '✗'} ${t.name}'
                '${t.error != null ? ' — ${t.error}' : ''}',
                t.pass ? Palette.get_ : Palette.delete,
              ),
            if (checks == 0 && res.error == null && !r.skipped)
              _detailLine(
                'No tests on this request — judged by status code.',
                Palette.textDim,
              ),
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

/// The first rows of a data file, as a table that scrolls sideways on narrow
/// screens, with the row and column counts.
class _DataPreview extends StatelessWidget {
  const _DataPreview(this.data);

  final DataFile data;

  /// Rows shown; the run itself uses all of them.
  static const previewRows = 20;

  @override
  Widget build(BuildContext context) {
    final shown = data.rows.take(previewRows).toList();
    final more = data.rows.length - shown.length;
    final head = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w700,
      color: Palette.text,
    );
    final cell = TextStyle(
      fontSize: 11.5,
      color: Palette.text,
      fontFamily: 'monospace',
    );
    Widget pad(String text, TextStyle style) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpHover(
          'The first $previewRows rows of the data, to check the columns '
          'before you run. The run uses every row.',
          title: 'Data preview',
          child: Text(
            more > 0
                ? 'Preview: first ${shown.length} of ${data.rows.length} rows'
                : 'Preview: ${data.rows.length} '
                      '${data.rows.length == 1 ? 'row' : 'rows'}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Palette.textDim,
            ),
          ),
        ),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Palette.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder(
                    horizontalInside: BorderSide(color: Palette.border),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: Palette.surface),
                      children: [
                        pad('#', head),
                        for (final c in data.columns) pad(c, head),
                      ],
                    ),
                    for (var i = 0; i < shown.length; i++)
                      TableRow(
                        children: [
                          pad('${i + 1}', cell),
                          for (final c in data.columns)
                            pad(shown[i][c] ?? '', cell),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
