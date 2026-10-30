import 'dart:convert';
import 'dart:io';

import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/cookie_jar.dart';
import 'package:api_workbench/services/cookie_store.dart';
import 'package:api_workbench/services/http_service.dart';
import 'package:api_workbench/services/json_store.dart';
import 'package:api_workbench/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 10, 31, 12);

/// A jar whose clock the test moves.
PersistentCookieJar _jar([Storage? store]) {
  final jar = PersistentCookieJar(store);
  var now = _t0;
  jar.clock = () => now;
  _clocks[jar] = (DateTime t) => now = t;
  return jar;
}

final _clocks = Expando<void Function(DateTime)>('clock');
void _setNow(PersistentCookieJar jar, DateTime t) => _clocks[jar]!(t);

List<String> _names(Iterable<StoredCookie> cs) => [for (final c in cs) c.name];

void main() {
  group('Set-Cookie parsing', () {
    test('reads every attribute', () {
      final c = SetCookie.parse(
        'id=a3fWa; Domain=.Example.COM; Path=/docs; Max-Age=60; Secure; '
        'HttpOnly; SameSite=lax; Expires=Wed, 21 Oct 2026 07:28:00 GMT',
      )!;
      expect(c.name, 'id');
      expect(c.value, 'a3fWa');
      expect(c.domain, 'example.com');
      expect(c.path, '/docs');
      expect(c.maxAge, 60);
      expect(c.secure, isTrue);
      expect(c.httpOnly, isTrue);
      expect(c.sameSite, 'Lax');
      expect(c.expires, DateTime.utc(2026, 10, 21, 7, 28));
    });

    test('keeps quotes and spaces that dart:io refuses', () {
      final quoted = SetCookie.parse('a="b c"; Path=/')!;
      expect(quoted.value, '"b c"');
      expect(quoted.path, '/');
      expect(SetCookie.parse('theme=dark mode')!.value, 'dark mode');
      expect(SetCookie.parse('a=b,c; Secure')!.value, 'b,c');
      expect(SetCookie.parse('a=café')!.value, 'café');
    });

    test(
      'ignores attributes it cannot read instead of dropping the cookie',
      () {
        final badAge = SetCookie.parse('a=b; Max-Age=soon; Path=/x')!;
        expect(badAge.maxAge, isNull);
        expect(badAge.path, '/x');
        final badDate = SetCookie.parse('a=b; Expires=whenever; Secure')!;
        expect(badDate.expires, isNull);
        expect(badDate.secure, isTrue);
        expect(SetCookie.parse('a=b; SameSite=Weird')!.sameSite, isNull);
        expect(SetCookie.parse('a=b; Path=relative')!.path, isNull);
        expect(SetCookie.parse('a=b; Domain=')!.domain, isNull);
      },
    );

    test('a huge Max-Age does not overflow', () {
      final big = SetCookie.parse('a=b; Max-Age=99999999999999999999999')!;
      expect(big.maxAge, greaterThan(0));
      final c = evaluateSetCookie(big, Uri.parse('http://x.test/'), now: _t0);
      expect(c.cookie!.expires!.isAfter(_t0), isTrue);
      final neg = SetCookie.parse('a=b; Max-Age=-99999999999999999999999')!;
      expect(neg.maxAge, lessThan(0));
    });

    test('rejects values with no name=value pair', () {
      expect(SetCookie.parse(''), isNull);
      expect(SetCookie.parse('   '), isNull);
      expect(SetCookie.parse('novalue'), isNull);
      expect(SetCookie.parse('=orphan'), isNull);
      expect(SetCookie.parse('; Path=/'), isNull);
      // An empty value is fine: that is how sites clear a cookie.
      expect(SetCookie.parse('a=; Path=/')!.value, '');
    });

    test('cookie dates in the spellings RFC 6265 allows', () {
      final want = DateTime.utc(2026, 10, 21, 7, 28);
      expect(parseCookieDate('Wed, 21 Oct 2026 07:28:00 GMT'), want);
      expect(parseCookieDate('Wednesday, 21-Oct-26 07:28:00 GMT'), want);
      expect(parseCookieDate('Wed Oct 21 07:28:00 2026'), want);
      expect(parseCookieDate('21 oct 2026 7:28:0'), want);
      expect(
        parseCookieDate('Sun, 06 Nov 94 08:49:37 GMT'),
        DateTime.utc(1994, 11, 6, 8, 49, 37),
      );
      expect(parseCookieDate('nonsense'), isNull);
      expect(parseCookieDate('31 Feb 2026 10:00:00'), isNull);
      expect(parseCookieDate('21 Oct 2026 25:00:00'), isNull);
    });
  });

  group('domain matching', () {
    test('without a Domain attribute the cookie is host-only', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://api.example.com/'), ['a=1']);
      expect(jar.cookieHeaderFor(Uri.parse('http://api.example.com/x')), 'a=1');
      expect(jar.cookieHeaderFor(Uri.parse('http://example.com/')), isNull);
      expect(
        jar.cookieHeaderFor(Uri.parse('http://v2.api.example.com/')),
        isNull,
      );
      expect(jar.cookieHeaderFor(Uri.parse('http://other.test/')), isNull);
    });

    test('a Domain cookie reaches subdomains', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://api.example.com/'), [
        'a=1; Domain=example.com',
      ]);
      for (final host in [
        'example.com',
        'api.example.com',
        'x.y.example.com',
      ]) {
        expect(
          jar.cookieHeaderFor(Uri.parse('http://$host/')),
          'a=1',
          reason: host,
        );
      }
      // A different site that merely ends in the same letters is not a
      // subdomain.
      expect(jar.cookieHeaderFor(Uri.parse('http://badexample.com/')), isNull);
      expect(
        jar.cookieHeaderFor(Uri.parse('http://example.com.evil.test/')),
        isNull,
      );
    });

    test('a leading dot and capitals in Domain make no difference', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://App.Example.com/'), [
        'a=1; Domain=.EXAMPLE.com',
      ]);
      expect(jar.domains().single.domain, 'example.com');
      expect(
        jar.cookieHeaderFor(Uri.parse('http://other.example.com/')),
        'a=1',
      );
    });

    test('rejects a Domain the request host does not match', () {
      final jar = _jar();
      final url = Uri.parse('http://app.example.com/');
      jar.saveFromResponse(url, [
        'a=1; Domain=other.com',
        'b=1; Domain=api.example.com', // a sibling
        'c=1; Domain=sub.app.example.com', // a child: only parents allowed
      ]);
      expect(jar.count, 0);
      final verdict = evaluateSetCookie(
        SetCookie.parse('a=1; Domain=other.com')!,
        url,
      );
      expect(verdict.cookie, isNull);
      expect(verdict.rejection, contains('does not match'));
    });

    test('rejects public suffixes but lets a host set its own name', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://shop.example.com/'), [
        'a=1; Domain=com',
        'b=1; Domain=.com',
      ]);
      jar.saveFromResponse(Uri.parse('http://shop.example.co.uk/'), [
        'c=1; Domain=co.uk',
      ]);
      expect(jar.count, 0);

      // "localhost" is a single label too, yet it may set a cookie for
      // itself: that becomes a host-only cookie.
      jar.saveFromResponse(Uri.parse('http://localhost:8080/'), [
        'd=1; Domain=localhost',
      ]);
      final d = jar.all().single;
      expect(d.domain, 'localhost');
      expect(d.hostOnly, isTrue);
      // Ports don't matter to cookies.
      expect(jar.cookieHeaderFor(Uri.parse('http://localhost:9999/')), 'd=1');
    });

    test('IP hosts are host-only', () {
      final jar = _jar();
      final url = Uri.parse('http://10.1.2.3:8080/');
      jar.saveFromResponse(url, [
        'a=1',
        'b=1; Domain=10.1.2.3',
        'c=1; Domain=2.3',
      ]);
      expect(_names(jar.all()), ['a', 'b']); // c: Domain is not the address
      expect(jar.all().every((c) => c.hostOnly), isTrue);
      expect(jar.cookieHeaderFor(Uri.parse('http://10.1.2.3/')), 'a=1; b=1');
      expect(jar.cookieHeaderFor(Uri.parse('http://10.1.2.4/')), isNull);
    });

    test('IPv6 literals work', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://[::1]:3000/'), ['a=1']);
      expect(jar.cookieHeaderFor(Uri.parse('http://[::1]:4000/x')), 'a=1');
    });

    test('hosts are compared case-insensitively', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://EXAMPLE.com/'), ['a=1']);
      expect(jar.cookieHeaderFor(Uri.parse('http://example.COM/')), 'a=1');
    });
  });

  group('path matching', () {
    test('default path', () {
      expect(defaultCookiePath(''), '/');
      expect(defaultCookiePath('/'), '/');
      expect(defaultCookiePath('/login'), '/');
      expect(defaultCookiePath('/a/b'), '/a');
      expect(defaultCookiePath('/a/b/'), '/a/b');
      expect(defaultCookiePath('/a/b/c.html'), '/a/b');
      expect(defaultCookiePath('relative'), '/');
    });

    test(
      'a cookie without Path takes the default path of the response URL',
      () {
        final jar = _jar();
        jar.saveFromResponse(Uri.parse('http://x.test/api/v1/login'), ['a=1']);
        expect(jar.all().single.path, '/api/v1');
        expect(
          jar.cookieHeaderFor(Uri.parse('http://x.test/api/v1/me')),
          'a=1',
        );
        expect(jar.cookieHeaderFor(Uri.parse('http://x.test/api/v1')), 'a=1');
        expect(
          jar.cookieHeaderFor(Uri.parse('http://x.test/api/v2/me')),
          isNull,
        );
        expect(jar.cookieHeaderFor(Uri.parse('http://x.test/')), isNull);
      },
    );

    test('path matching follows RFC 6265 5.1.4', () {
      expect(cookiePathMatches('/foo', '/foo'), isTrue);
      expect(cookiePathMatches('/foo/bar', '/foo'), isTrue);
      expect(cookiePathMatches('/foo/', '/foo'), isTrue);
      expect(cookiePathMatches('/foo/bar', '/foo/'), isTrue);
      expect(cookiePathMatches('/foobar', '/foo'), isFalse); // not a directory
      expect(cookiePathMatches('/fo', '/foo'), isFalse);
      expect(cookiePathMatches('/', '/'), isTrue);
      expect(cookiePathMatches('/anything', '/'), isTrue);
      expect(cookiePathMatches('', '/'), isTrue);
    });

    test('an explicit Path is honoured', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/login'), [
        'a=1; Path=/admin',
      ]);
      expect(
        jar.cookieHeaderFor(Uri.parse('http://x.test/admin/users')),
        'a=1',
      );
      expect(
        jar.cookieHeaderFor(Uri.parse('http://x.test/administrator')),
        isNull,
      );
      expect(jar.cookieHeaderFor(Uri.parse('http://x.test/login')), isNull);
    });
  });

  group('expiry', () {
    test('Max-Age counts from when the cookie arrived', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['a=1; Max-Age=60']);
      expect(jar.all().single.expires, _t0.add(const Duration(seconds: 60)));
      final url = Uri.parse('http://x.test/');
      _setNow(jar, _t0.add(const Duration(seconds: 59)));
      expect(jar.cookieHeaderFor(url), 'a=1');
      _setNow(jar, _t0.add(const Duration(seconds: 60)));
      expect(jar.cookieHeaderFor(url), isNull);
      expect(jar.count, 0, reason: 'expired cookies are dropped');
    });

    test('Max-Age takes precedence over Expires', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), [
        // Expires says long gone, Max-Age says an hour.
        'a=1; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=3600',
        // Expires says far away, Max-Age says now.
        'b=1; Expires=Wed, 01 Jan 2200 00:00:00 GMT; Max-Age=0',
      ]);
      expect(_names(jar.all()), ['a']);
      expect(jar.all().single.expires, _t0.add(const Duration(hours: 1)));
    });

    test('Max-Age <= 0 deletes an existing cookie', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/');
      jar.saveFromResponse(url, ['a=1', 'b=1', 'c=1']);
      jar.saveFromResponse(url, ['a=; Max-Age=0']);
      jar.saveFromResponse(url, ['b=; Max-Age=-1']);
      expect(_names(jar.all()), ['c']);
    });

    test('a past Expires deletes; a future one keeps', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/');
      jar.saveFromResponse(url, [
        'a=1; Expires=Wed, 01 Jan 2200 00:00:00 GMT',
        'b=1',
      ]);
      expect(jar.count, 2);
      jar.saveFromResponse(url, ['a=; Expires=Thu, 01 Jan 1970 00:00:00 GMT']);
      expect(_names(jar.all()), ['b']);
    });

    test('an unreadable Expires makes a session cookie, not a rejection', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['a=1; Expires=oops']);
      expect(jar.all().single.isSession, isTrue);
    });

    test('a past Expires that never existed stores nothing', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), [
        'a=1; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      ]);
      expect(jar.count, 0);
    });
  });

  group('Secure', () {
    test('goes only to https, except on loopback', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('https://x.test/'), [
        's=1; Secure',
        'p=1',
      ]);
      expect(jar.cookieHeaderFor(Uri.parse('https://x.test/')), 's=1; p=1');
      expect(jar.cookieHeaderFor(Uri.parse('http://x.test/')), 'p=1');
    });

    test('localhost and 127.0.0.1 count as secure, as in browsers', () {
      final jar = _jar();
      for (final host in ['localhost', '127.0.0.1', 'app.localhost', '[::1]']) {
        jar.clear();
        jar.saveFromResponse(Uri.parse('http://$host:3000/'), ['s=1; Secure']);
        expect(
          jar.cookieHeaderFor(Uri.parse('http://$host:3000/')),
          's=1',
          reason: host,
        );
      }
      expect(isSecureCookieContext(Uri.parse('http://127.0.0.2/')), isTrue);
      expect(isSecureCookieContext(Uri.parse('http://128.0.0.1/')), isFalse);
      expect(isSecureCookieContext(Uri.parse('http://notlocalhost/')), isFalse);
    });

    test('HttpOnly and SameSite are kept for display only', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), [
        'a=1; HttpOnly; SameSite=Strict',
      ]);
      final c = jar.all().single;
      expect(c.httpOnly, isTrue);
      expect(c.sameSite, 'Strict');
      // Sent regardless: an API client has no cross-site context.
      expect(jar.cookieHeaderFor(Uri.parse('http://x.test/')), 'a=1');
    });
  });

  group('replacement and ordering', () {
    test('same name, domain and path replaces; others stay', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/app/');
      jar.saveFromResponse(url, ['a=1; Path=/', 'a=2; Path=/app', 'b=1']);
      jar.saveFromResponse(url, ['a=3; Path=/']);
      expect(jar.count, 3);
      expect(
        jar.cookieHeaderFor(Uri.parse('http://x.test/app/z')),
        'a=2; b=1; a=3',
      );
      // Another domain with the same name and path is a different cookie.
      jar.saveFromResponse(Uri.parse('http://y.test/'), ['a=other']);
      expect(jar.count, 4);
    });

    test('a replacement keeps the original creation time', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/');
      jar.saveFromResponse(url, ['a=1']);
      _setNow(jar, _t0.add(const Duration(minutes: 5)));
      jar.saveFromResponse(url, ['a=2']);
      expect(jar.all().single.created, _t0);
      expect(jar.all().single.value, '2');
    });

    test('longer paths first, then earlier creation', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/a/b/c');
      jar.saveFromResponse(url, ['root1=1; Path=/']);
      _setNow(jar, _t0.add(const Duration(seconds: 1)));
      jar.saveFromResponse(url, ['deep=1; Path=/a/b', 'mid=1; Path=/a']);
      _setNow(jar, _t0.add(const Duration(seconds: 2)));
      jar.saveFromResponse(url, ['root2=1; Path=/', 'deep2=1; Path=/a/b']);
      expect(
        jar.cookieHeaderFor(url),
        'deep=1; deep2=1; mid=1; root1=1; root2=1',
      );
    });

    test('cookies set together keep their order', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/');
      final names = [
        for (var i = 0; i < 40; i++) 'c${i.toString().padLeft(2, '0')}',
      ];
      jar.saveFromResponse(url, [for (final n in names) '$n=1']);
      expect(jar.cookieHeaderFor(url), names.map((n) => '$n=1').join('; '));
    });

    test('cookiesFor returns detached dart:io cookies', () {
      final jar = _jar();
      final url = Uri.parse('https://x.test/');
      jar.saveFromResponse(url, [
        'a="two words"; Path=/; Secure; SameSite=Lax',
      ]);
      final c = jar.cookiesFor(url).single;
      expect(c.name, 'a');
      expect(c.value, '"two words"');
      expect(c.domain, 'x.test');
      expect(c.secure, isTrue);
      expect(c.sameSite, SameSite.lax);
      c.value = 'changed';
      expect(jar.all().single.value, '"two words"');
    });

    test('the jar is capped per domain, dropping the oldest', () {
      final jar = _jar();
      final url = Uri.parse('http://x.test/');
      for (var i = 0; i < PersistentCookieJar.maxPerDomain + 5; i++) {
        _setNow(jar, _t0.add(Duration(seconds: i)));
        jar.saveFromResponse(url, ['c$i=1']);
      }
      expect(jar.count, PersistentCookieJar.maxPerDomain);
      expect(jar.cookiesIn('x.test').any((c) => c.name == 'c0'), isFalse);
      expect(jar.cookiesIn('x.test').any((c) => c.name == 'c184'), isTrue);
    });
  });

  group('malformed input', () {
    test('never throws and never stores junk', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), [
        '',
        ';;;',
        '=',
        'justtext',
        '=value',
        'a b=c',
        '\u0000=x',
        'ok=1',
        'a=b; ; ; Secure; =; Path',
      ]);
      expect(_names(jar.all()).toSet(), containsAll(['ok']));
      expect(
        jar.cookieHeaderFor(Uri.parse('http://x.test/')),
        contains('ok=1'),
      );
    });

    test('a URL without a host is ignored', () {
      final jar = _jar();
      jar.saveFromResponse(Uri.parse('/relative'), ['a=1']);
      expect(jar.count, 0);
      expect(jar.cookieHeaderFor(Uri.parse('/relative')), isNull);
    });
  });

  group('manager API', () {
    StoredCookie make(
      String name,
      String domain, {
      String path = '/',
      bool hostOnly = true,
    }) => StoredCookie(
      name: name,
      value: 'v',
      domain: domain,
      path: path,
      hostOnly: hostOnly,
      created: _t0,
    );

    test('lists domains with counts and the cookies of one', () {
      final jar = _jar();
      jar
        ..add(make('b', 'b.test'))
        ..add(make('a', 'a.test'))
        ..add(make('z', 'a.test'))
        ..add(make('z', 'a.test', path: '/p'));
      expect(jar.domains().map((d) => '${d.domain}:${d.count}').toList(), [
        'a.test:3',
        'b.test:1',
      ]);
      expect(
        jar.cookiesIn('a.test').map((c) => '${c.name}${c.path}').toList(),
        ['a/', 'z/', 'z/p'],
      );
      expect(jar.cookiesIn('none.test'), isEmpty);
    });

    test('add, update, delete, clear a domain, clear everything', () {
      final jar = _jar();
      final events = <int>[];
      final sub = jar.changes.listen((_) => events.add(jar.version));
      addTearDown(sub.cancel);

      final a = make('a', 'a.test');
      jar.add(a);
      jar.add(make('b', 'a.test'));
      jar.add(make('c', 'c.test'));

      // Edit in place: the value changes, identity and order don't.
      jar.update(
        a,
        StoredCookie(
          name: 'a',
          value: 'edited',
          domain: 'a.test',
          created: _t0,
        ),
      );
      expect(jar.cookiesIn('a.test').first.value, 'edited');
      expect(jar.count, 3);

      // Edit the identity: renaming moves the cookie.
      final renamed = StoredCookie(
        name: 'a2',
        value: 'v',
        domain: 'a.test',
        created: _t0,
      );
      jar.update(jar.cookiesIn('a.test').first, renamed);
      expect(_names(jar.cookiesIn('a.test')), ['a2', 'b']);

      expect(jar.delete(renamed), isTrue);
      expect(jar.delete(renamed), isFalse);
      expect(jar.clearDomain('a.test'), 1);
      expect(jar.clearDomain('a.test'), 0);
      expect(_names(jar.all()), ['c']);
      jar.clear();
      expect(jar.count, 0);

      return Future<void>.delayed(Duration.zero).then((_) {
        expect(events, isNotEmpty);
        expect(events.last, jar.version);
      });
    });

    test('changes fire once per change and not for reads', () async {
      final jar = _jar();
      var fired = 0;
      final sub = jar.changes.listen((_) => fired++);
      addTearDown(sub.cancel);
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['a=1', 'b=2']);
      jar.cookieHeaderFor(Uri.parse('http://x.test/'));
      jar.all();
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['nope']);
      await Future<void>.delayed(Duration.zero);
      expect(fired, 1);
    });

    test('a hand-typed Set-Cookie line becomes a cookie', () {
      final c = cookieFromLine(
        'sid=abc 123; Path=/api; Secure; HttpOnly; SameSite=None; Max-Age=3600',
        ' https://Api.Example.com/ ',
        now: _t0,
      );
      expect(c.domain, 'api.example.com');
      expect(c.hostOnly, isTrue);
      expect(c.value, 'abc 123');
      expect(c.path, '/api');
      expect(c.secure && c.httpOnly, isTrue);
      expect(c.sameSite, 'None');
      expect(c.expires, _t0.add(const Duration(hours: 1)));

      final shared = cookieFromLine('a=1; Domain=example.com', 'example.com');
      expect(shared.hostOnly, isFalse);

      expect(
        () => cookieFromLine('nonsense', 'x.test'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => cookieFromLine('a=1', '  '),
        throwsA(isA<FormatException>()),
      );
    });

    test('the editable line round-trips', () {
      final c = StoredCookie(
        name: 'sid',
        value: 'v',
        domain: 'example.com',
        hostOnly: false,
        path: '/a',
        expires: DateTime.utc(2030, 1, 2, 3, 4, 5),
        secure: true,
        httpOnly: true,
        sameSite: 'Lax',
        created: _t0,
      );
      final back = cookieFromLine(c.toSetCookieLine(), c.domain, now: _t0);
      expect(back.key, c.key);
      expect(back.hostOnly, isFalse);
      expect(back.expires, c.expires);
      expect(back.secure && back.httpOnly, isTrue);
      expect(back.sameSite, 'Lax');
    });
  });

  group('persistence', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('aw_ck_'));
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('survives a restart, session cookies included', () async {
      final storage = Storage(overrideDir: dir);
      final jar = _jar(storage);
      jar.saveFromResponse(Uri.parse('https://api.example.com/v1/login'), [
        'session=abc 123; HttpOnly; Secure',
        'theme="dark"; Path=/; Domain=example.com; Max-Age=86400; SameSite=Lax',
      ]);
      await jar.flush();
      await storage.flush();

      final reborn = _jar(Storage(overrideDir: dir));
      await reborn.load();
      expect(
        reborn.all().map((c) => c.toJson()).toList(),
        jar.all().map((c) => c.toJson()).toList(),
      );
      final url = Uri.parse('https://api.example.com/v1/me');
      expect(reborn.cookieHeaderFor(url), 'session=abc 123; theme="dark"');
      final session = reborn.cookiesIn('api.example.com').single;
      expect(session.isSession, isTrue);
      expect(session.httpOnly && session.secure, isTrue);
    });

    test('expired cookies are dropped on load', () async {
      final storage = Storage(overrideDir: dir);
      final jar = _jar(storage);
      jar.saveFromResponse(Uri.parse('http://x.test/'), [
        'short=1; Max-Age=30',
        'long=1; Max-Age=86400',
      ]);
      await jar.flush();

      final reborn = _jar(Storage(overrideDir: dir));
      _setNow(reborn, _t0.add(const Duration(minutes: 10)));
      await reborn.load();
      expect(_names(reborn.all()), ['long']);
    });

    test('changes are debounced into one write', () async {
      final store = _CountingStore();
      final jar = _jar();
      final persisted = PersistentCookieJar(store)
        ..clock = jar.clock
        ..saveDelay = const Duration(milliseconds: 30);
      final url = Uri.parse('http://x.test/');
      for (var i = 0; i < 20; i++) {
        persisted.saveFromResponse(url, ['c$i=1']);
      }
      expect(store.writes, 0, reason: 'nothing is written synchronously');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await persisted.flush();
      expect(store.writes, 1);
      expect((store.last as Map)['cookies'], hasLength(20));
    });

    test('flush writes now and writes never overlap', () async {
      final store = _CountingStore(slow: true);
      final jar = PersistentCookieJar(store)
        ..saveDelay = const Duration(hours: 1);
      final url = Uri.parse('http://x.test/');
      jar.saveFromResponse(url, ['a=1']);
      final first = jar.flush();
      jar.saveFromResponse(url, ['b=1']);
      final second = jar.flush();
      await Future.wait([first, second]);
      expect(store.writes, 2);
      expect(store.maxConcurrent, 1);
      expect((store.last as Map)['cookies'], hasLength(2));
    });

    test('a failing store does not break the jar', () async {
      final jar = PersistentCookieJar(_CountingStore(fail: true));
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['a=1']);
      await jar.flush();
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['b=1']);
      await jar.flush();
      expect(jar.count, 2);
    });

    test('a corrupt or foreign cookies.json is tolerated', () async {
      final base = Directory('${dir.path}/apiworkbench')..createSync();
      File('${base.path}/cookies.json').writeAsStringSync('{not json');
      final jar = PersistentCookieJar(Storage(overrideDir: dir));
      await jar.load();
      expect(jar.count, 0);

      File('${base.path}/cookies.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'cookies': [
            'junk',
            {'name': 'x'},
            {'name': 'ok', 'value': '1', 'domain': 'X.test'},
            {'name': '', 'value': '1', 'domain': 'x.test'},
            {
              'name': 'typed',
              'value': '1',
              'domain': 'x.test',
              'hostOnly': 'yes',
            },
          ],
        }),
      );
      await jar.load();
      expect(_names(jar.all()), ['ok', 'typed']);
      expect(
        jar.all().every((c) => c.domain == 'x.test' && c.hostOnly),
        isTrue,
      );
    });

    test('a jar without a store works in memory', () async {
      final jar = PersistentCookieJar();
      jar.saveFromResponse(Uri.parse('http://x.test/'), ['a=1']);
      await jar.load();
      await jar.flush();
      expect(jar.cookieHeaderFor(Uri.parse('http://x.test/')), 'a=1');
    });
  });

  group('through HttpService', () {
    late HttpServer server;
    late String base;
    final seen = <({String path, String? cookie})>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        seen.add((path: req.uri.path, cookie: req.headers.value('cookie')));
        final res = req.response;
        switch (req.uri.path) {
          case '/login':
            // The cookie is set on the redirect itself.
            res.headers.add('set-cookie', 'session=s3cret; Path=/; HttpOnly');
            res.headers.add('set-cookie', 'api=1; Path=/api');
            res.headers.add('set-cookie', 'wide=1; Domain=127.0.0.1; Path=/');
            res.headers.add('set-cookie', 'tls=1; Secure');
            res.statusCode = 302;
            res.headers.set('location', '/home');
          case '/hop':
            res.statusCode = 302;
            res.headers.set('location', '/home');
          case '/logout':
            res.headers.add('set-cookie', 'session=; Max-Age=0; Path=/');
          case '/rotate':
            res.headers.add('set-cookie', 'session=r0tated; Path=/');
          default:
            res.write('ok');
        }
        await res.close();
      });
    });
    tearDown(() => server.close(force: true));

    Future<ResponseData> get(
      HttpService http,
      String path, {
      bool cookies = true,
    }) => http.send(
      RequestModel(
        url: '$base$path',
        settings: RequestSettings(useCookies: cookies),
      ),
      const {},
      tabId: 't',
    );

    test(
      'login sets a cookie that later requests send, across a redirect',
      () async {
        final http = HttpService()..cookieJar = PersistentCookieJar();
        addTearDown(http.dispose);

        final res = await get(http, '/login');
        expect(res.statusCode, 200);
        expect(res.finalUrl, '$base/home');
        // The redirect target already carried the cookies set by /login.
        expect(seen.last.path, '/home');
        expect(seen.last.cookie, 'session=s3cret; wide=1; tls=1');

        // A follow-up request sends them too, longest path first.
        await get(http, '/api/users');
        expect(seen.last.cookie, 'api=1; session=s3cret; wide=1; tls=1');

        // Cookies for /api don't leak to other paths.
        await get(http, '/other');
        expect(seen.last.cookie, 'session=s3cret; wide=1; tls=1');
      },
    );

    test('cookies set mid-chain reach the hops after it', () async {
      final http = HttpService()..cookieJar = PersistentCookieJar();
      addTearDown(http.dispose);
      await get(http, '/rotate');
      await get(http, '/hop');
      expect(seen.map((s) => s.path).toList(), ['/rotate', '/hop', '/home']);
      expect(seen[1].cookie, 'session=r0tated');
      expect(seen[2].cookie, 'session=r0tated');
    });

    test('a cookie deleted by the server is no longer sent', () async {
      final http = HttpService()..cookieJar = PersistentCookieJar();
      addTearDown(http.dispose);
      await get(http, '/rotate');
      await get(http, '/logout');
      await get(http, '/home');
      expect(seen.last.cookie, isNull);
    });

    test('opting out neither sends nor stores', () async {
      final jar = PersistentCookieJar();
      final http = HttpService()..cookieJar = jar;
      addTearDown(http.dispose);
      await get(http, '/rotate', cookies: false);
      expect(jar.count, 0);
      await get(http, '/rotate');
      await get(http, '/home', cookies: false);
      expect(seen.last.cookie, isNull);
    });

    test('a host-only cookie stays on its own host name', () async {
      final jar = PersistentCookieJar();
      final http = HttpService()..cookieJar = jar;
      addTearDown(http.dispose);
      await get(http, '/rotate');
      // Same server, but reached as "localhost": a different host.
      await http.send(
        RequestModel(url: 'http://localhost:${server.port}/home'),
        const {},
        tabId: 't',
      );
      expect(seen.last.cookie, isNull);
    });

    test('cookies the user typed in the Cookie header are kept', () async {
      final http = HttpService()..cookieJar = PersistentCookieJar();
      addTearDown(http.dispose);
      await get(http, '/rotate');
      await http.send(
        RequestModel(
          url: '$base/home',
          headers: [KV(key: 'Cookie', value: 'mine=1')],
        ),
        const {},
        tabId: 't',
      );
      expect(seen.last.cookie, 'mine=1; session=r0tated');
    });
  });
}

/// A [JsonStore] that counts and optionally slows or fails writes.
class _CountingStore implements JsonStore {
  _CountingStore({this.slow = false, this.fail = false});
  final bool slow;
  final bool fail;
  int writes = 0;
  int _running = 0;
  int maxConcurrent = 0;
  Object? last;

  @override
  Future<Object?> readJson(String name) async => null;

  @override
  Future<void> writeJson(String name, Object data) async {
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 20));
    _running--;
    if (fail) throw const FileSystemException('disk full');
    writes++;
    last = jsonDecode(jsonEncode(data));
  }
}
