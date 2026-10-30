import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/prepared_request.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/protocols/sse_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protocols_support.dart';

void main() {
  group('SseParser', () {
    List<SseEvent> parse(Iterable<String> chunks, [SseParser? p]) {
      final parser = p ?? SseParser();
      return [for (final c in chunks) ...parser.add(c)];
    }

    test('parses data, event, id and retry fields', () {
      final events = parse([
        'id: 7\nevent: tick\nretry: 2500\ndata: hello\n\n',
      ]);
      expect(events, hasLength(1));
      expect(events.single.data, 'hello');
      expect(events.single.event, 'tick');
      expect(events.single.id, '7');
      expect(events.single.retry, 2500);
    });

    test('joins multi-line data with newlines', () {
      final events = parse(['data: one\ndata: two\ndata:\ndata: four\n\n']);
      expect(events.single.data, 'one\ntwo\n\nfour');
      expect(events.single.event, 'message');
    });

    test('removes only one leading space from a value', () {
      expect(parse(['data:  two spaces\n\n']).single.data, ' two spaces');
      expect(parse(['data:none\n\n']).single.data, 'none');
    });

    test('ignores comments, unknown fields and blocks without data', () {
      final comments = <String>[];
      final events = parse([
        ': keep-alive\nfoo: bar\n\nid: 3\n\ndata: x\n\n',
      ], SseParser(onComment: comments.add));
      expect(events.map((e) => e.data), ['x']);
      expect(comments, ['keep-alive']);
    });

    test('handles CRLF, CR and LF line ends, even split across chunks', () {
      final events = parse(['data: a\r\n\r\ndata: b\r\rdata: c\n\n']);
      expect(events.map((e) => e.data), ['a', 'b', 'c']);
      final split = parse(['data: a\r', '\n\r', '\ndata: b\n', '\n']);
      expect(split.map((e) => e.data), ['a', 'b']);
    });

    test('reassembles events split anywhere in the byte stream', () {
      const wire =
          'id: 1\nevent: e\ndata: first\ndata: line2\n\ndata: next\n\n';
      for (var cut = 1; cut < wire.length; cut++) {
        final events = parse([wire.substring(0, cut), wire.substring(cut)]);
        expect(events.map((e) => e.data), [
          'first\nline2',
          'next',
        ], reason: 'cut at $cut');
        expect(events.first.id, '1');
      }
    });

    test('drops a byte order mark and remembers the last id', () {
      final p = SseParser();
      final events = parse(['﻿data: x\nid: 9\n\ndata: y\n\n'], p);
      expect(events.map((e) => e.data), ['x', 'y']);
      expect(events.first.id, '9');
      expect(events.last.id, isNull);
      expect(p.lastEventId, '9');
    });

    test(
      'a field without a colon has an empty value; bad retry is ignored',
      () {
        final retries = <Duration>[];
        final events = parse([
          'data\n\ndata: z\nretry: soon\nretry: 100\n\n',
        ], SseParser(onRetry: retries.add));
        expect(events.map((e) => e.data), ['', 'z']);
        expect(retries, [const Duration(milliseconds: 100)]);
      },
    );

    test('an unfinished event at the end is not delivered', () {
      expect(parse(['data: partial\n']), isEmpty);
    });
  });

  group('SSE against a local server', () {
    late HttpServer server;
    late int port;
    final requests = <HttpRequest>[];
    final bodies = <String>[];
    var streamHits = 0;

    setUp(() async {
      requests.clear();
      bodies.clear();
      streamHits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((req) async {
        requests.add(req);
        final res = req.response;
        if (req.uri.path == '/missing') {
          res.statusCode = 404;
          res.write('nothing here');
          await res.close();
          return;
        }
        bodies.add(await utf8.decoder.bind(req).join());
        res.headers.contentType = ContentType('text', 'event-stream');
        res.bufferOutput = false;
        if (req.uri.path == '/resume') {
          streamHits++;
          if (streamHits == 1) {
            res.write('retry: 30\nid: 41\ndata: first\n\n');
            await res.flush();
            // Split the next event across two writes, then drop the stream.
            res.write('id: 42\ndata: sec');
            await res.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
            res.write('ond\ndata: line\n\n');
            await res.close();
          } else {
            res.write(
              'data: resumed from ${req.headers.value('last-event-id')}\n\n',
            );
            await res.flush();
            // Keep this one open.
            await Future<void>.delayed(const Duration(seconds: 30));
          }
          return;
        }
        res.write(': hello\nevent: greet\nid: a1\ndata: {"n":1}\n\n');
        res.write('data: plain\n\n');
        await res.flush();
        if (req.uri.path == '/finite') await res.close();
        await Future<void>.delayed(const Duration(seconds: 30));
      });
    });

    tearDown(() => server.close(force: true));

    SseConfig config(
      String path, {
      String method = 'GET',
      String body = '',
      bool auto = true,
      List<MapEntry<String, String>> headers = const [],
    }) => SseConfig(
      url: Uri.parse('http://127.0.0.1:$port$path'),
      method: method,
      body: body,
      headers: headers,
      autoReconnect: auto,
      defaultRetry: const Duration(milliseconds: 30),
      showComments: true,
    );

    test('streams events with their id, name and data', () async {
      final c = SseConnection();
      await c.start(config('/stream'));
      await waitFor(
        () =>
            c.log.entries
                .where((e) => e.direction == Direction.received)
                .length >=
            3,
      );
      final events = c.log.entries
          .where((e) => e.direction == Direction.received)
          .toList();
      expect(events[0].label, 'comment');
      expect(events[1].label, 'greet');
      expect(events[1].meta['id'], 'a1');
      expect(events[1].text, '{"n":1}');
      expect(events[1].prettyText, contains('"n": 1'));
      expect(events[2].label, 'message');
      expect(events[2].text, 'plain');
      expect(c.state, LinkState.connected);
      expect(c.lastEventId, 'a1');
      expect(requests.single.headers.value('accept'), 'text/event-stream');
      c.stop();
      expect(c.state, LinkState.idle);
      c.close();
    });

    test('streams through the client the app provides', () async {
      var built = 0;
      final c = SseConnection();
      await c.start(
        SseConfig(
          url: Uri.parse('http://127.0.0.1:$port/stream'),
          clientFactory: () {
            built++;
            return HttpClient();
          },
        ),
      );
      await waitFor(() => c.log.entries.any((e) => e.text == 'plain'));
      expect(built, 1);
      c.close();
    });

    test('sends request headers', () async {
      final c = SseConnection();
      await c.start(
        config('/stream', headers: [const MapEntry('X-Key', 'abc')]),
      );
      await waitFor(() => requests.isNotEmpty);
      expect(requests.single.headers.value('x-key'), 'abc');
      c.close();
    });

    test('reconnects with Last-Event-ID after the retry delay', () async {
      final c = SseConnection();
      await c.start(config('/resume'));
      await waitFor(
        () => c.log.entries.any((e) => e.text.startsWith('resumed from')),
        reason: 'resumed event',
      );
      expect(
        c.log.entries.any(
          (e) => e.text == 'second\nline' && e.meta['id'] == '42',
        ),
        isTrue,
      );
      expect(requests, hasLength(2));
      expect(requests.first.headers.value('last-event-id'), isNull);
      expect(requests.last.headers.value('last-event-id'), '42');
      expect(c.log.entries.any((e) => e.text == 'resumed from 42'), isTrue);
      expect(c.retry, const Duration(milliseconds: 30));
      c.close();
    });

    test('without auto-reconnect the stream ends and stays ended', () async {
      final c = SseConnection();
      await c.start(config('/finite', auto: false));
      await waitFor(() => c.state == LinkState.idle);
      expect(requests, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, hasLength(1));
      c.close();
    });

    test('Stop cancels a pending reconnect', () async {
      final c = SseConnection();
      await c.start(
        SseConfig(
          url: Uri.parse('http://127.0.0.1:$port/finite'),
          defaultRetry: const Duration(seconds: 5),
        ),
      );
      await waitFor(() => c.state == LinkState.reconnecting);
      c.stop();
      expect(c.state, LinkState.idle);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(requests, hasLength(1));
      c.close();
    });

    test('POST sends the body', () async {
      final c = SseConnection();
      await c.start(config('/stream', method: 'POST', body: '{"prompt":"hi"}'));
      await waitFor(() => bodies.isNotEmpty);
      expect(requests.single.method, 'POST');
      expect(bodies.single, '{"prompt":"hi"}');
      expect(requests.single.headers.contentType?.mimeType, 'application/json');
      c.close();
    });

    test('a 404 is reported and not retried', () async {
      final c = SseConnection();
      await c.start(config('/missing'));
      expect(c.state, LinkState.idle);
      expect(c.statusCode, 404);
      final err = c.log.entries.last;
      expect(err.isError, isTrue);
      expect(err.text, contains('404'));
      expect(err.text, contains('nothing here'));
      c.close();
    });

    test('connection refused is reported', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      final c = SseConnection();
      await c.start(
        SseConfig(
          url: Uri.parse('http://127.0.0.1:$deadPort/'),
          autoReconnect: false,
        ),
      );
      expect(c.state, LinkState.idle);
      expect(c.log.entries.any((e) => e.isError), isTrue);
      c.close();
    });
  });

  group('SSE config', () {
    test('builds from a request with variables, params and headers', () {
      final r = RequestModel(
        kind: RequestKind.sse,
        method: 'POST',
        url: '{{host}}/events',
        params: [KV(key: 'topic', value: 'a b')],
        headers: [KV(key: 'Authorization', value: 'Bearer {{t}}')],
        body: '{"q":"{{q}}"}',
        protocolConfig: {'autoReconnect': false, 'defaultRetryMs': 1500},
      );
      final c = SseConfig.fromRequest(r, {
        'host': 'http://h.test',
        't': 'k',
        'q': 'x',
      });
      expect(c.url.toString(), 'http://h.test/events?topic=a%20b');
      expect(c.method, 'POST');
      expect(c.headers.single.value, 'Bearer k');
      expect(c.body, '{"q":"x"}');
      expect(c.autoReconnect, isFalse);
      expect(c.defaultRetry, const Duration(milliseconds: 1500));
    });

    test('GET never sends a body; other methods fall back to GET', () {
      final c = SseConfig.fromRequest(
        RequestModel(
          kind: RequestKind.sse,
          method: 'PUT',
          url: 'http://h.test',
          body: 'x',
        ),
        {},
      );
      expect(c.method, 'GET');
      expect(c.body, '');
    });

    test('rejects non-HTTP schemes', () {
      expect(
        () => SseConfig.fromRequest(
          RequestModel(kind: RequestKind.sse, url: 'ws://h.test'),
          {},
        ),
        throwsA(isA<RequestBuildException>()),
      );
    });

    test('settings round trip', () {
      final s = SseSettings(
        autoReconnect: false,
        defaultRetryMs: 10,
        maxReconnects: 3,
        showComments: true,
      );
      final back = SseSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.autoReconnect, isFalse);
      expect(back.defaultRetryMs, 10);
      expect(back.maxReconnects, 3);
      expect(back.showComments, isTrue);
      expect(SseSettings.fromJson({}).autoReconnect, isTrue);
    });
  });
}
