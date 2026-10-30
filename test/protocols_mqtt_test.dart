import 'dart:convert';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/prepared_request.dart';
import 'package:api_workbench/services/protocols/live_connection.dart';
import 'package:api_workbench/services/protocols/mqtt_connection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protocols_support.dart';

void main() {
  group('MQTT broker URL', () {
    test('understands every scheme and the default ports', () {
      MqttEndpoint e(String u) => MqttEndpoint.parse(u);
      expect(
        (e('mqtt://broker.test').scheme, e('mqtt://broker.test').port),
        ('tcp', 1883),
      );
      expect((e('tcp://b:1884').scheme, e('tcp://b:1884').port), ('tcp', 1884));
      expect((e('mqtts://b').scheme, e('mqtts://b').port), ('ssl', 8883));
      expect((e('ssl://b:8884').scheme, e('ssl://b:8884').port), ('ssl', 8884));
      expect((e('ws://b/mqtt').scheme, e('ws://b/mqtt').port), ('ws', 80));
      expect((e('wss://b').scheme, e('wss://b').port), ('wss', 443));
      expect(e('wss://b:8084/mqtt?x=1').websocketUrl, 'wss://b/mqtt?x=1');
      expect(e('wss://b:8084/mqtt').display, 'wss://b:8084/mqtt');
      expect(e('localhost:1883').host, 'localhost');
      expect(e('localhost:1883').port, 1883);
      expect(e('localhost:1883').scheme, 'tcp');
      expect(e('ssl://b').secure, isTrue);
      expect(e('ws://b').websocket, isTrue);
      expect(e('tcp://b').secure, isFalse);
    });

    test('rejects what it cannot use', () {
      expect(() => MqttEndpoint.parse(''), throwsFormatException);
      expect(() => MqttEndpoint.parse('http://b'), throwsFormatException);
      expect(() => MqttEndpoint.parse('mqtt://'), throwsFormatException);
    });
  });

  group('MQTT topics', () {
    test('publish topics', () {
      expect(validatePublishTopic('a/b/c'), isNull);
      expect(validatePublishTopic(r'$SYS/x'), isNull);
      expect(validatePublishTopic(''), isNotNull);
      expect(validatePublishTopic('a/+'), isNotNull);
      expect(validatePublishTopic('a/#'), isNotNull);
    });

    test('subscription filters', () {
      for (final ok in [
        'a',
        'a/b',
        '#',
        'a/#',
        '+',
        'a/+/c',
        '+/+',
        '/a',
        'a/',
      ]) {
        expect(validateSubscribeFilter(ok), isNull, reason: ok);
      }
      for (final bad in ['', 'a#', 'a/#/b', '#/a', 'a+', 'a/b+', 'a/+b']) {
        expect(validateSubscribeFilter(bad), isNotNull, reason: bad);
      }
    });

    test('wildcard matching', () {
      expect(topicMatches('a/b', 'a/b'), isTrue);
      expect(topicMatches('a/b', 'a/c'), isFalse);
      expect(topicMatches('a/+', 'a/b'), isTrue);
      expect(topicMatches('a/+', 'a/b/c'), isFalse);
      expect(topicMatches('a/+/c', 'a/b/c'), isTrue);
      expect(topicMatches('a/#', 'a'), isTrue);
      expect(topicMatches('a/#', 'a/b/c'), isTrue);
      expect(topicMatches('#', 'x/y'), isTrue);
      expect(topicMatches('+/b', 'a/b'), isTrue);
      expect(topicMatches('a/b/c', 'a/b'), isFalse);
      expect(topicMatches('#', r'$SYS/x'), isFalse);
      expect(topicMatches('+/x', r'$SYS/x'), isFalse);
      expect(topicMatches(r'$SYS/#', r'$SYS/x'), isTrue);
    });
  });

  group('MQTT settings and config', () {
    test('settings round trip and tolerate junk', () {
      final s = MqttSettings(
        clientId: 'me',
        username: 'u',
        password: 'p',
        keepAlive: 30,
        cleanSession: false,
        autoReconnect: true,
        willEnabled: true,
        willTopic: 'will/t',
        willPayload: 'gone',
        willQos: 2,
        willRetain: true,
        pubTopic: 'a/b',
        pubPayload: '{"x":1}',
        pubKind: PayloadKind.json,
        pubQos: 1,
        pubRetain: true,
        subscriptions: [MqttSubscription(topic: 'a/#', qos: 1, enabled: false)],
      );
      final back = MqttSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.clientId, 'me');
      expect(back.keepAlive, 30);
      expect(back.cleanSession, isFalse);
      expect(back.willQos, 2);
      expect(back.willRetain, isTrue);
      expect(back.pubKind, PayloadKind.json);
      expect(back.pubQos, 1);
      expect(back.subscriptions.single.topic, 'a/#');
      expect(back.subscriptions.single.enabled, isFalse);

      final junk = MqttSettings.fromJson({
        'keepAlive': 'x',
        'willQos': 9,
        'subscriptions': [
          'x',
          3,
          {'topic': 5, 'qos': 7},
        ],
      });
      expect(junk.keepAlive, 60);
      expect(junk.willQos, 2);
      expect(junk.subscriptions.single.qos, 2);
      expect(junk.subscriptions.single.topic, '');
    });

    test('config comes from the request with variables', () {
      final r = RequestModel(
        kind: RequestKind.mqtt,
        url: '{{broker}}',
        headers: [KV(key: 'X-Key', value: 'k')],
        protocolConfig: {
          'clientId': 'dev-{{n}}',
          'username': '{{u}}',
          'password': 'pw',
          'keepAlive': 20,
          'willEnabled': true,
          'willTopic': 'status/{{n}}',
          'willPayload': 'offline',
          'willQos': 1,
          'subscriptions': [
            {'topic': 'in/{{n}}/#', 'qos': 1, 'enabled': true},
            {'topic': 'off', 'enabled': false},
            {'topic': '  '},
          ],
        },
      );
      final c = MqttConfig.fromRequest(r, {
        'broker': 'ws://broker.test:8083/mqtt',
        'n': '7',
        'u': 'me',
      });
      expect(c.endpoint.websocket, isTrue);
      expect(c.endpoint.port, 8083);
      expect(c.endpoint.path, '/mqtt');
      expect(c.clientId, 'dev-7');
      expect(c.username, 'me');
      expect(c.keepAlive, 20);
      expect(c.willTopic, 'status/7');
      expect(c.willQos, 1);
      expect(c.headers, {'X-Key': 'k'});
      expect(c.subscriptions.map((s) => s.topic), ['in/7/#']);
    });

    test('an empty client id is generated', () {
      final c = MqttConfig.fromRequest(
        RequestModel(kind: RequestKind.mqtt, url: 'mqtt://localhost'),
        {},
      );
      expect(c.clientId, startsWith('apiworkbench-'));
      expect(c.clientId.length, 'apiworkbench-'.length + 8);
      expect(randomClientId(), isNot(randomClientId()));
    });

    test('bad URLs and bad will topics are reported', () {
      expect(
        () => MqttConfig.fromRequest(
          RequestModel(kind: RequestKind.mqtt, url: 'http://x'),
          {},
        ),
        throwsA(isA<RequestBuildException>()),
      );
      expect(
        () => MqttConfig.fromRequest(
          RequestModel(
            kind: RequestKind.mqtt,
            url: 'mqtt://x',
            protocolConfig: {'willEnabled': true, 'willTopic': 'a/#'},
          ),
          {},
        ),
        throwsFormatException,
      );
    });
  });

  group('MQTT against a local broker', () {
    late MockMqttBroker broker;

    setUp(() async => broker = await MockMqttBroker.start());
    tearDown(() => broker.close());

    MqttConfig config({
      String? url,
      String user = '',
      String pass = '',
      String? willTopic,
      List<MqttSubscription> subs = const [],
      bool auto = false,
      Map<String, Object> headers = const {},
      bool clean = true,
    }) => MqttConfig(
      endpoint: MqttEndpoint.parse(url ?? 'mqtt://127.0.0.1:${broker.tcpPort}'),
      clientId: 'test-client',
      username: user,
      password: pass,
      keepAlive: 30,
      cleanSession: clean,
      autoReconnect: auto,
      willTopic: willTopic,
      willPayload: 'bye',
      willQos: 1,
      willRetain: true,
      subscriptions: subs,
      headers: headers,
    );

    Future<MqttConnection> connected(MqttConfig c) async {
      final conn = MqttConnection();
      await conn.connect(c);
      await waitFor(
        () => conn.state == LinkState.connected,
        reason: 'connected: ${conn.log.entries.map((e) => e.text)}',
      );
      return conn;
    }

    test('sends the connect options', () async {
      final c = await connected(
        config(
          user: 'me',
          pass: 'secret',
          willTopic: 'status/me',
          clean: false,
        ),
      );
      final seen = broker.connects.single;
      expect(seen.clientId, 'test-client');
      expect(seen.user, 'me');
      expect(seen.password, 'secret');
      expect(seen.keepAlive, 30);
      expect(seen.clean, isFalse);
      expect(seen.will, isNotNull);
      expect(seen.will!.topic, 'status/me');
      expect(seen.will!.message, 'bye');
      expect(seen.will!.qos, 1);
      expect(seen.will!.retain, isTrue);
      expect(c.clientId, 'test-client');
      c.close();
    });

    test('subscribes and logs messages with topic, QoS and retain', () async {
      final c = await connected(
        config(subs: [MqttSubscription(topic: 'sensors/+/temp', qos: 1)]),
      );
      await waitFor(() => broker.subscribed.isNotEmpty);
      expect(broker.subscribed.single.filter, 'sensors/+/temp');
      expect(broker.subscribed.single.qos, 1);
      expect(c.subscribedTopics, {'sensors/+/temp'});

      broker.inject('sensors/a/temp', utf8.encode('{"t":21.5}'), qos: 1);
      broker.inject('sensors/b/humidity', utf8.encode('x')); // not subscribed
      broker.inject('sensors/c/temp', utf8.encode('hot'), qos: 0, retain: true);
      await waitFor(
        () =>
            c.log.entries
                .where((e) => e.direction == Direction.received)
                .length >=
            2,
      );
      final got = c.log.entries
          .where((e) => e.direction == Direction.received)
          .toList();
      expect(got[0].title, 'sensors/a/temp');
      expect(got[0].text, '{"t":21.5}');
      expect(got[0].prettyText, contains('"t": 21.5'));
      expect(got[0].meta['QoS'], '1');
      expect(got[0].meta['retain'], 'false');
      expect(got[1].title, 'sensors/c/temp');
      expect(got[1].meta['QoS'], '0');
      expect(c.counts['sensors/+/temp'], 2);
      c.close();
    });

    test('publishes with QoS and retain', () async {
      final c = await connected(config());
      c.publish('cmd/light', const Payload.text('on'), qos: 1, retain: true);
      c.publish(
        'cmd/bin',
        Payload.binary(decodeBase64Input('AAEC/w==')),
        qos: 2,
      );
      c.publish('cmd/plain', const Payload.text('hello'));
      await waitFor(() => broker.published.length == 3);
      expect(broker.published[0].topic, 'cmd/light');
      expect(utf8.decode(broker.published[0].payload), 'on');
      expect(broker.published[0].qos, 1);
      expect(broker.published[0].retain, isTrue);
      expect(broker.published[1].payload, [0, 1, 2, 255]);
      expect(broker.published[1].qos, 2);
      expect(broker.published[2].qos, 0);
      final sent = c.log.entries
          .where((e) => e.direction == Direction.sent)
          .toList();
      expect(sent[0].meta, {'QoS': '1', 'retain': 'true'});
      expect(sent[1].isBinary, isTrue);
      expect(sent[1].bytes, [0, 1, 2, 255]);
      c.close();
    });

    test('a retained message arrives on subscribe', () async {
      broker.retained['state/x'] = (payload: utf8.encode('kept'), qos: 0);
      final c = await connected(config());
      c.subscribe('state/#', 0);
      await waitFor(() => c.log.entries.any((e) => e.text == 'kept'));
      expect(
        c.log.entries.firstWhere((e) => e.text == 'kept').meta['retain'],
        'true',
      );
      c.close();
    });

    test('unsubscribing stops delivery', () async {
      final c = await connected(config());
      c.subscribe('a/b', 0);
      await waitFor(() => broker.subscribed.isNotEmpty);
      broker.inject('a/b', utf8.encode('one'));
      await waitFor(() => c.log.entries.any((e) => e.text == 'one'));
      c.unsubscribe('a/b');
      await waitFor(() => broker.unsubscribed.isNotEmpty);
      expect(broker.unsubscribed.single, 'a/b');
      expect(c.subscribedTopics, isEmpty);
      broker.inject('a/b', utf8.encode('two'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.log.entries.any((e) => e.text == 'two'), isFalse);
      c.close();
    });

    test('binary payloads are kept as bytes', () async {
      final c = await connected(config());
      c.subscribe('bin', 0);
      await waitFor(() => broker.subscribed.isNotEmpty);
      broker.inject('bin', [0, 255, 7]);
      await waitFor(() => c.log.entries.any((e) => e.isBinary));
      expect(c.log.entries.firstWhere((e) => e.isBinary).bytes, [0, 255, 7]);
      c.close();
    });

    test('checks topics and the connection before acting', () async {
      final idle = MqttConnection();
      expect(
        () => idle.publish('a', const Payload.text('x')),
        throwsStateError,
      );
      expect(() => idle.subscribe('a', 0), throwsStateError);
      idle.close();
      final c = await connected(config());
      expect(
        () => c.publish('a/+', const Payload.text('x')),
        throwsFormatException,
      );
      expect(
        () => c.publish('', const Payload.text('x')),
        throwsFormatException,
      );
      expect(() => c.subscribe('a/#/b', 0), throwsFormatException);
      c.close();
    });

    test('bad credentials are explained', () async {
      final c = MqttConnection();
      await c.connect(config(user: 'bad', pass: 'x'));
      await waitFor(() => c.state == LinkState.idle);
      expect(
        c.log.entries.where((e) => e.isError).map((e) => e.text).join(' '),
        contains('bad user name or password'),
      );
      c.close();
    });

    test('connection refused is reported', () async {
      final port = broker.tcpPort;
      await broker.close();
      final c = MqttConnection();
      await c.connect(config(url: 'mqtt://127.0.0.1:$port'));
      await waitFor(() => c.state == LinkState.idle);
      expect(c.log.entries.any((e) => e.isError), isTrue);
      c.close();
    });

    test('disconnects cleanly', () async {
      final c = await connected(config());
      c.disconnect();
      await waitFor(() => c.state == LinkState.idle);
      await waitFor(() => broker.disconnects == 1);
      expect(c.log.entries.last.text, 'Disconnected');
      c.close();
    });

    test('notices when the broker drops the connection', () async {
      final c = await connected(config());
      broker.dropClients();
      await waitFor(() => c.state == LinkState.idle);
      expect(
        c.log.entries.any((e) => e.text == 'The broker closed the connection'),
        isTrue,
      );
      c.close();
    });

    test('reconnects and resubscribes when auto-reconnect is on', () async {
      final c = await connected(
        config(auto: true, subs: [MqttSubscription(topic: 'keep/#', qos: 0)]),
      );
      await waitFor(() => broker.subscribed.isNotEmpty);
      broker.dropClients();
      await waitFor(
        () => broker.connects.length >= 2,
        timeout: const Duration(seconds: 15),
      );
      await waitFor(
        () => c.state == LinkState.connected && broker.subscribed.length >= 2,
        timeout: const Duration(seconds: 15),
      );
      broker.inject('keep/x', utf8.encode('after'));
      await waitFor(() => c.log.entries.any((e) => e.text == 'after'));
      c.close();
    });

    test('works over WebSocket with headers', () async {
      final c = await connected(
        config(
          url: 'ws://127.0.0.1:${broker.wsPort}/mqtt?token=1',
          headers: {'X-Key': 'k'},
          subs: [MqttSubscription(topic: 'w/#', qos: 0)],
        ),
      );
      final up = broker.upgrades.single;
      expect(up.uri.path, '/mqtt');
      expect(up.uri.queryParameters['token'], '1');
      expect(up.headers.value('x-key'), 'k');
      await waitFor(() => broker.subscribed.isNotEmpty);
      broker.inject('w/1', utf8.encode('over ws'));
      await waitFor(() => c.log.entries.any((e) => e.text == 'over ws'));
      c.publish('w/out', const Payload.text('x'));
      await waitFor(() => broker.published.isNotEmpty);
      c.close();
    });
  });
}
