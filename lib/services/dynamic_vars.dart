import 'dart:math';

import 'package:uuid/uuid.dart';

/// Postman-compatible dynamic variables: `{{$guid}}`, `{{$timestamp}}`,
/// `{{$randomEmail}}`… A fresh value is generated for every occurrence.
/// Returns null for names this app does not know, so the placeholder is
/// left untouched.
String? dynamicVariable(String name) {
  final gen = _generators[name];
  return gen?.call();
}

/// Every supported dynamic variable name (with the leading `$`).
Iterable<String> get dynamicVariableNames => _generators.keys;

final _rng = Random();
const _uuid = Uuid();

T _pick<T>(List<T> xs) => xs[_rng.nextInt(xs.length)];
int _int(int min, int max) => min + _rng.nextInt(max - min + 1);
String _alnum(int n) {
  const cs = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(n, (_) => cs[_rng.nextInt(cs.length)]).join();
}

String _hex(int n) =>
    List.generate(n, (_) => _rng.nextInt(16).toRadixString(16)).join();

const _first = [
  'Aarav', 'Ada', 'Ben', 'Chloe', 'Diego', 'Elena', 'Farah', 'George', //
  'Hana', 'Ivan', 'Jasmine', 'Kai', 'Leila', 'Mateo', 'Nina', 'Omar',
  'Priya', 'Quinn', 'Ravi', 'Sofia', 'Tom', 'Uma', 'Victor', 'Wen',
];
const _last = [
  'Anderson', 'Brown', 'Chen', 'Dubois', 'Evans', 'Fernandez', 'Gupta', //
  'Hansen', 'Ito', 'Johnson', 'Kumar', 'Lopez', 'Muller', 'Nakamura',
  'Okafor', 'Patel', 'Rossi', 'Silva', 'Taylor', 'Wang',
];
const _words = [
  'alpha', 'bridge', 'cloud', 'delta', 'ember', 'forest', 'granite', //
  'harbor', 'island', 'jungle', 'kernel', 'lantern', 'meadow', 'nebula',
  'orbit', 'pixel', 'quartz', 'river', 'signal', 'timber', 'vector',
];
const _cities = [
  'Chennai', 'Berlin', 'Tokyo', 'Toronto', 'Lisbon', 'Nairobi', 'Austin', //
  'Seoul', 'Melbourne', 'Bogotá', 'Oslo', 'Cairo',
];
const _countries = [
  ('India', 'IN'), ('Germany', 'DE'), ('Japan', 'JP'), ('Canada', 'CA'), //
  ('Portugal', 'PT'), ('Kenya', 'KE'), ('United States', 'US'),
  ('South Korea', 'KR'), ('Australia', 'AU'), ('Brazil', 'BR'),
];
const _companies = [
  'Acme',
  'Globex',
  'Initech',
  'Umbrella',
  'Hooli',
  'Vandelay',
];
const _jobs = ['Engineer', 'Designer', 'Analyst', 'Manager', 'Consultant'];
const _tlds = ['com', 'net', 'org', 'io', 'dev'];
const _currencies = ['USD', 'EUR', 'INR', 'JPY', 'GBP', 'AUD', 'CAD'];
const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

String _sentence() {
  final n = _int(5, 10);
  final w = List.generate(n, (_) => _pick(_words));
  return '${w.first[0].toUpperCase()}${w.first.substring(1)} '
      '${w.skip(1).join(' ')}.';
}

String _date(int fromDays, int toDays) => DateTime.now()
    .add(Duration(days: _int(fromDays, toDays), seconds: _int(0, 86399)))
    .toUtc()
    .toIso8601String();

final Map<String, String Function()> _generators = {
  // Common
  r'$guid': () => _uuid.v4(),
  r'$randomUUID': () => _uuid.v4(),
  r'$timestamp': () => '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
  r'$isoTimestamp': () => DateTime.now().toUtc().toIso8601String(),
  r'$randomInt': () => '${_int(0, 1000)}',
  r'$randomAlphaNumeric': () => _alnum(1),
  r'$randomBoolean': () => '${_rng.nextBool()}',
  // Text and numbers
  r'$randomWord': () => _pick(_words),
  r'$randomWords': () =>
      List.generate(_int(2, 5), (_) => _pick(_words)).join(' '),
  r'$randomLoremWord': () => _pick(_words),
  r'$randomLoremWords': () => List.generate(3, (_) => _pick(_words)).join(' '),
  r'$randomLoremSentence': _sentence,
  r'$randomLoremParagraph': () =>
      List.generate(3, (_) => _sentence()).join(' '),
  r'$randomLoremSlug': () => List.generate(3, (_) => _pick(_words)).join('-'),
  r'$randomHexColor': () => '#${_hex(6)}',
  r'$randomColor': () =>
      _pick(['red', 'green', 'blue', 'teal', 'orange', 'purple']),
  r'$randomAbbreviation': () =>
      _pick(['API', 'HTTP', 'JSON', 'SQL', 'TCP', 'XML']),
  r'$randomSemver': () => '${_int(0, 9)}.${_int(0, 20)}.${_int(0, 50)}',
  // Internet
  r'$randomIP': () => List.generate(4, (_) => _int(1, 254)).join('.'),
  r'$randomIPV6': () => List.generate(8, (_) => _hex(4)).join(':'),
  r'$randomMACAddress': () => List.generate(6, (_) => _hex(2)).join(':'),
  r'$randomPassword': () => _alnum(15),
  r'$randomUserName': () => '${_pick(_first).toLowerCase()}${_int(1, 999)}',
  r'$randomDomainName': () => '${_pick(_words)}.${_pick(_tlds)}',
  r'$randomDomainWord': () => _pick(_words),
  r'$randomDomainSuffix': () => _pick(_tlds),
  r'$randomUrl': () => 'https://${_pick(_words)}.${_pick(_tlds)}',
  r'$randomEmail': () =>
      '${_pick(_first).toLowerCase()}.${_pick(_last).toLowerCase()}'
      '@${_pick(_words)}.${_pick(_tlds)}',
  r'$randomExampleEmail': () =>
      '${_pick(_first).toLowerCase()}${_int(1, 99)}@example.com',
  r'$randomProtocol': () => _pick(['http', 'https']),
  r'$randomUserAgent': () =>
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/${_int(100, 130)}.0 Safari/537.36',
  r'$randomLocale': () => _pick(['en', 'de', 'fr', 'ja', 'ta', 'pt']),
  // Names
  r'$randomFirstName': () => _pick(_first),
  r'$randomLastName': () => _pick(_last),
  r'$randomFullName': () => '${_pick(_first)} ${_pick(_last)}',
  r'$randomNamePrefix': () => _pick(['Mr.', 'Ms.', 'Mrs.', 'Dr.']),
  r'$randomNameSuffix': () => _pick(['Jr.', 'Sr.', 'II', 'III', 'PhD']),
  r'$randomJobTitle': () =>
      '${_pick(['Senior', 'Lead', 'Junior'])} ${_pick(_jobs)}',
  r'$randomJobType': () => _pick(_jobs),
  r'$randomPhoneNumber': () =>
      '${_int(200, 999)}-${_int(200, 999)}-${_int(1000, 9999)}',
  // Location
  r'$randomCity': () => _pick(_cities),
  r'$randomCountry': () => _pick(_countries).$1,
  r'$randomCountryCode': () => _pick(_countries).$2,
  r'$randomStreetName': () => '${_pick(_words)} Street',
  r'$randomStreetAddress': () => '${_int(1, 999)} ${_pick(_words)} Street',
  r'$randomLatitude': () => (_rng.nextDouble() * 180 - 90).toStringAsFixed(4),
  r'$randomLongitude': () => (_rng.nextDouble() * 360 - 180).toStringAsFixed(4),
  // Business and finance
  r'$randomCompanyName': () =>
      '${_pick(_companies)} ${_pick(['Inc', 'Ltd', 'LLC', 'Group'])}',
  r'$randomPrice': () => (_rng.nextDouble() * 1000).toStringAsFixed(2),
  r'$randomCurrencyCode': () => _pick(_currencies),
  r'$randomBankAccount': () => '${_int(10000000, 99999999)}',
  // Dates
  r'$randomDateFuture': () => _date(1, 365),
  r'$randomDatePast': () => _date(-365, -1),
  r'$randomDateRecent': () => _date(-2, 0),
  r'$randomWeekday': () => _pick(_weekdays),
  r'$randomMonth': () => _pick(_months),
};
