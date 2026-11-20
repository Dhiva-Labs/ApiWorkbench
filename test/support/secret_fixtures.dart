import 'package:api_workbench/models/models.dart';

/// Every credential the fixtures below carry. None of them may appear in a
/// saved file.
const fixtureSecrets = [
  'col-bearer-0001',
  'folder-pass-0002',
  'oauth-access-0003',
  'oauth-refresh-0004',
  'oauth-client-secret-0005',
  'hdr-bearer-0006',
  'mqtt-pass-0007',
  'example-key-0008',
  'colvar-initial-0009',
  'colvar-current-0010',
  'env-initial-0011',
  'env-current-0012',
  'global-secret-0013',
  'proxy-pass-0014',
  'cert-pass-0015',
  'basic-pass-0016',
  'cookie-0017',
];

/// Values that are not secrets and must stay in the files.
const fixturePlain = [
  'https://api.example.com/orders',
  'alice',
  'keep-me-header',
  'plain-variable-value',
  'proxy.example.com',
];

CollectionModel secretCollection({String id = 'col-1'}) => CollectionModel(
  id: id,
  name: 'Orders',
  auth: AuthConfig(type: AuthType.bearer, bearerToken: 'col-bearer-0001'),
  variables: [
    KV(key: 'base', value: 'plain-variable-value'),
    KV(
      key: 'apiSecret',
      value: 'colvar-initial-0009',
      current: 'colvar-current-0010',
      secret: true,
    ),
  ],
  folders: {
    'Admin/Users': FolderMeta(
      auth: AuthConfig(
        type: AuthType.basic,
        basicUser: 'alice',
        basicPassword: 'folder-pass-0002',
      ),
    ),
  },
  requests: [
    RequestModel(
      id: 'req-1',
      name: 'List orders',
      url: 'https://api.example.com/orders',
      folder: 'Admin/Users',
      headers: [
        KV(key: 'Authorization', value: 'Bearer hdr-bearer-0006'),
        KV(key: 'Cookie', value: 'session=cookie-0017'),
        KV(key: 'X-Trace', value: 'keep-me-header'),
      ],
      auth: AuthConfig(
        type: AuthType.oauth2,
        params: {
          'accessToken': 'oauth-access-0003',
          'refreshToken': 'oauth-refresh-0004',
          'clientSecret': 'oauth-client-secret-0005',
          'clientId': 'client-id-public',
          'grant_type': 'client_credentials',
        },
      ),
      examples: [
        ResponseExample(
          id: 'ex-1',
          originalRequest: RequestModel(
            id: 'req-1',
            url: 'https://api.example.com/orders',
            auth: AuthConfig(
              type: AuthType.apiKey,
              apiKeyName: 'X-Key',
              apiKeyValue: 'example-key-0008',
            ),
          ),
        ),
      ],
    ),
    RequestModel(
      id: 'req-2',
      name: 'Broker',
      kind: RequestKind.mqtt,
      url: 'mqtt://broker.example.com',
      basicUser: 'alice',
      basicPassword: 'basic-pass-0016',
      protocolConfig: {'username': 'alice', 'password': 'mqtt-pass-0007'},
    ),
  ],
);

EnvironmentModel secretEnvironment({String id = 'env-1'}) => EnvironmentModel(
  id: id,
  name: 'Prod',
  variables: [
    KV(key: 'host', value: 'proxy.example.com'),
    KV(
      key: 'token',
      value: 'env-initial-0011',
      current: 'env-current-0012',
      secret: true,
    ),
  ],
);

List<KV> secretGlobals() => [
  KV(key: 'gsecret', value: 'global-secret-0013', secret: true),
];

AppSettings secretSettings() => AppSettings(
  network: NetworkSettings(
    proxyMode: ProxyMode.custom,
    proxyHost: 'proxy.example.com',
    proxyUser: 'alice',
    proxyPassword: 'proxy-pass-0014',
    clientCerts: [
      ClientCertificate(
        id: 'cert-1',
        host: 'api.example.com',
        pfxPath: '/certs/me.p12',
        passphrase: 'cert-pass-0015',
      ),
    ],
  ),
);
