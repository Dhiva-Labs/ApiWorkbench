import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/digests/md4.dart';

import '../../models/models.dart';
import '../request_builder.dart';
import 'auth.dart';
import 'auth_util.dart';

/// MD4 (RFC 1320), which NTLM needs for the NT hash. `package:crypto`
/// lacks it; pointycastle (already used for RSA and ECDSA) has it.
Uint8List md4(List<int> data) => MD4Digest().process(Uint8List.fromList(data));

/// NTLMv2 over HTTP (MS-NLMP): the NEGOTIATE message goes with the first
/// request, the server's 401 carries the CHALLENGE, and the retry sends the
/// AUTHENTICATE message. The connection is kept alive in between, which
/// NTLM needs.
abstract final class NtlmAuth {
  static const _signature = [
    0x4e,
    0x54,
    0x4c,
    0x4d,
    0x53,
    0x53,
    0x50,
    0,
  ]; // NTLMSSP\0

  static const flagUnicode = 0x00000001;
  static const flagOem = 0x00000002;
  static const flagRequestTarget = 0x00000004;
  static const flagNtlm = 0x00000200;
  static const flagAlwaysSign = 0x00008000;
  static const flagExtendedSessionSecurity = 0x00080000;
  static const flagTargetInfo = 0x00800000;
  static const flag128 = 0x20000000;
  static const flag56 = 0x80000000;

  static const negotiateFlags =
      flagUnicode |
      flagOem |
      flagRequestTarget |
      flagNtlm |
      flagAlwaysSign |
      flagExtendedSessionSecurity |
      flagTargetInfo |
      flag128 |
      flag56;

  static void apply(PreparedRequest p, AuthConfig auth, AuthContext ctx) {
    // A snippet can't hold a handshake; nothing useful to add.
    if (ctx.offline) return;
    p.headers.set('Authorization', 'NTLM ${base64.encode(negotiate())}');
  }

  static PreparedRequest? retry(
    PreparedRequest sent,
    ResponseData res,
    AuthConfig auth,
    AuthContext ctx,
  ) {
    if (authFlag(auth, 'disableRetryRequest')) return null;
    final blob = parseChallenges(wwwAuthenticate(res))
        .where((c) => c.isScheme('NTLM') && c.token68 != null)
        .firstOrNull
        ?.token68;
    if (blob == null) return null;
    final NtlmChallenge challenge;
    try {
      challenge = NtlmChallenge.parse(base64.decode(blob));
    } on FormatException {
      return null;
    }
    var user = ctx.param(auth, 'username');
    var domain = ctx.param(auth, 'domain');
    // DOMAIN\user in the username field.
    final slash = user.indexOf(r'\');
    if (domain.isEmpty && slash > 0) {
      domain = user.substring(0, slash);
      user = user.substring(slash + 1);
    }
    final msg = authenticate(
      challenge: challenge,
      user: user,
      password: ctx.param(auth, 'password'),
      domain: domain,
      workstation: ctx.param(auth, 'workstation'),
      clientChallenge: randomBytes(8),
      time: ctx.now(),
    );
    return sent.copy()
      ..headers.set('Authorization', 'NTLM ${base64.encode(msg)}');
  }

  /// NEGOTIATE_MESSAGE (type 1) without domain or workstation.
  static Uint8List negotiate() {
    final b = BytesBuilder()
      ..add(_signature)
      ..add(_u32(1))
      ..add(_u32(negotiateFlags))
      ..add(_secBuf(0, 32)) // domain
      ..add(_secBuf(0, 32)); // workstation
    return b.toBytes();
  }

  /// NTOWFv2 (= LMOWFv2): HMAC-MD5 of the user and domain keyed with the
  /// NT hash of the password.
  static Uint8List ntowfv2(String password, String user, String domain) {
    final ntHash = md4(utf16le(password));
    return _hmacMd5(ntHash, utf16le(user.toUpperCase() + domain));
  }

  /// The NTLMv2 and LMv2 responses of MS-NLMP §3.3.2.
  static ({
    Uint8List ntProofStr,
    Uint8List ntResponse,
    Uint8List lmResponse,
    Uint8List sessionBaseKey,
  })
  responses({
    required Uint8List responseKey,
    required Uint8List serverChallenge,
    required Uint8List clientChallenge,
    required Uint8List timestamp,
    required Uint8List targetInfo,
  }) {
    final temp = BytesBuilder()
      ..add([1, 1, 0, 0, 0, 0, 0, 0])
      ..add(timestamp)
      ..add(clientChallenge)
      ..add([0, 0, 0, 0])
      ..add(targetInfo)
      ..add([0, 0, 0, 0]);
    final tempBytes = temp.toBytes();
    final ntProof = _hmacMd5(responseKey, [...serverChallenge, ...tempBytes]);
    return (
      ntProofStr: ntProof,
      ntResponse: Uint8List.fromList([...ntProof, ...tempBytes]),
      lmResponse: Uint8List.fromList([
        ..._hmacMd5(responseKey, [...serverChallenge, ...clientChallenge]),
        ...clientChallenge,
      ]),
      sessionBaseKey: _hmacMd5(responseKey, ntProof),
    );
  }

  /// AUTHENTICATE_MESSAGE (type 3) answering [challenge].
  static Uint8List authenticate({
    required NtlmChallenge challenge,
    required String user,
    required String password,
    required String domain,
    required String workstation,
    required Uint8List clientChallenge,
    required DateTime time,
  }) {
    final key = ntowfv2(password, user, domain);
    final serverTime = challenge.avPairs[7];
    final r = responses(
      responseKey: key,
      serverChallenge: challenge.serverChallenge,
      clientChallenge: clientChallenge,
      timestamp: serverTime ?? fileTime(time),
      targetInfo: challenge.targetInfo,
    );
    // With a server timestamp the LMv2 response SHOULD be Z(24) (§3.1.5.1.2).
    final lm = serverTime != null ? Uint8List(24) : r.lmResponse;
    final unicode = challenge.flags & flagUnicode != 0;
    List<int> str(String s) => unicode ? utf16le(s) : latin1.encode(s);
    final dom = str(domain);
    final usr = str(user);
    final ws = str(workstation);
    const headerSize = 64;
    var offset = headerSize;
    List<int> field(List<int> data) {
      final f = _secBuf(data.length, offset);
      offset += data.length;
      return f;
    }

    final flags =
        (challenge.flags & negotiateFlags) |
        (unicode ? flagUnicode : flagOem) |
        flagNtlm;
    final b = BytesBuilder()
      ..add(_signature)
      ..add(_u32(3))
      ..add(field(lm))
      ..add(field(r.ntResponse))
      ..add(field(dom))
      ..add(field(usr))
      ..add(field(ws))
      ..add(field(const [])) // encrypted random session key
      ..add(_u32(flags))
      ..add(lm)
      ..add(r.ntResponse)
      ..add(dom)
      ..add(usr)
      ..add(ws);
    return b.toBytes();
  }

  /// Windows FILETIME: 100 ns ticks since 1601-01-01, little-endian.
  static Uint8List fileTime(DateTime t) {
    final ticks =
        BigInt.from(t.toUtc().microsecondsSinceEpoch) * BigInt.from(10) +
        BigInt.parse('116444736000000000');
    final out = Uint8List(8);
    var v = ticks;
    for (var i = 0; i < 8; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v >>= 8;
    }
    return out;
  }

  static Uint8List utf16le(String s) {
    final out = Uint8List(s.length * 2);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      out[i * 2] = c & 0xff;
      out[i * 2 + 1] = c >> 8;
    }
    return out;
  }

  static Uint8List _hmacMd5(List<int> key, List<int> data) =>
      Uint8List.fromList(Hmac(md5, key).convert(data).bytes);

  static List<int> _u32(int v) => [
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  static List<int> _secBuf(int len, int offset) => [
    len & 0xff,
    len >> 8,
    len & 0xff,
    len >> 8,
    ..._u32(offset),
  ];
}

/// A parsed CHALLENGE_MESSAGE (type 2).
class NtlmChallenge {
  NtlmChallenge({
    required this.flags,
    required this.serverChallenge,
    required this.targetInfo,
    this.targetName = '',
  });

  final int flags;
  final Uint8List serverChallenge;

  /// The raw AV_PAIR list, echoed in the NTLMv2 response.
  final Uint8List targetInfo;
  final String targetName;

  /// AV pairs by id (2 = NetBIOS domain, 7 = timestamp, ...).
  Map<int, Uint8List> get avPairs {
    final out = <int, Uint8List>{};
    var i = 0;
    while (i + 4 <= targetInfo.length) {
      final id = targetInfo[i] | targetInfo[i + 1] << 8;
      final len = targetInfo[i + 2] | targetInfo[i + 3] << 8;
      if (id == 0 || i + 4 + len > targetInfo.length) break;
      out[id] = Uint8List.sublistView(targetInfo, i + 4, i + 4 + len);
      i += 4 + len;
    }
    return out;
  }

  /// Throws [FormatException] for anything that isn't a type 2 message.
  factory NtlmChallenge.parse(Uint8List m) {
    if (m.length < 32 ||
        utf8.decode(m.sublist(0, 7), allowMalformed: true) != 'NTLMSSP' ||
        _u32(m, 8) != 2) {
      throw const FormatException('not an NTLM challenge');
    }
    Uint8List buf(int at) {
      if (at + 8 > m.length) return Uint8List(0);
      final len = m[at] | m[at + 1] << 8;
      final off = _u32(m, at + 4);
      if (len == 0 || off + len > m.length) return Uint8List(0);
      return Uint8List.sublistView(m, off, off + len);
    }

    final flags = _u32(m, 20);
    final name = buf(12);
    return NtlmChallenge(
      flags: flags,
      serverChallenge: Uint8List.fromList(m.sublist(24, 32)),
      targetInfo: m.length >= 48 ? Uint8List.fromList(buf(40)) : Uint8List(0),
      targetName: flags & NtlmAuth.flagUnicode != 0
          ? String.fromCharCodes([
              for (var i = 0; i + 1 < name.length; i += 2)
                name[i] | name[i + 1] << 8,
            ])
          : latin1.decode(name),
    );
  }

  static int _u32(Uint8List b, int at) =>
      b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;
}
