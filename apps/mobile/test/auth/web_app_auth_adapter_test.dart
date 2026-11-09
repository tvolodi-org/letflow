// PWA M2 (D-112): web OIDC redirect flow with PKCE (W1-W5) and the web token
// store split (S1). No browser: location, sessionStorage and HTTP are faked.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/transport_policy.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/auth/web_app_auth_adapter.dart';
import 'package:letflow/auth/web_pointer_kv.dart';

const _issuer = 'https://idp.example/realms/acme';
const _redirect = 'https://app.example/mobile/';

class MapStorage implements StringStorage {
  final Map<String, String> m = {};
  @override
  String? getItem(String key) => m[key];
  @override
  void setItem(String key, String value) => m[key] = value;
  @override
  void removeItem(String key) => m.remove(key);
}

class FakeLocation implements WebLocation {
  FakeLocation(this.current);
  @override
  Uri current;
  final List<String> assigned = [];
  final List<String> replaced = [];
  @override
  String get redirectUri => _redirect;
  @override
  void assign(String url) => assigned.add(url);
  @override
  void replaceState(String url) {
    replaced.add(url);
    current = Uri.parse(url);
  }
}

class Call {
  Call(this.url, this.form);
  final Uri url;
  final Map<String, String>? form;
}

class FakeOidcHttp implements OidcHttp {
  final List<Call> calls = [];
  late Map<String, dynamic> discovery;
  late Map<String, dynamic> tokenBody;

  @override
  Future<Map<String, dynamic>> getJson(Uri url) async {
    calls.add(Call(url, null));
    return discovery;
  }

  @override
  Future<Map<String, dynamic>> postForm(
    Uri url,
    Map<String, String> form,
  ) async {
    calls.add(Call(url, form));
    return tokenBody;
  }
}

String _jwt(Map<String, dynamic> claims) =>
    'h.${base64UrlNoPad(utf8.encode(jsonEncode(claims)))}.s';

void main() {
  late FakeOidcHttp http;
  late MapStorage session;
  late FakeLocation location;
  late WebAppAuthAdapter adapter;

  AuthorizationTokenRequest req({String issuer = _issuer, String id = 'cid'}) =>
      AuthorizationTokenRequest(
        id,
        kOidcRedirectUrl,
        issuer: issuer,
        scopes: kOidcScopes,
      );

  setUp(() {
    http = FakeOidcHttp();
    session = MapStorage();
    location = FakeLocation(Uri.parse(_redirect));
    http.discovery = {
      'issuer': _issuer,
      'authorization_endpoint': '$_issuer/protocol/openid-connect/auth',
      'token_endpoint': '$_issuer/protocol/openid-connect/token',
    };
    http.tokenBody = {
      'access_token': 'at',
      'refresh_token': 'rt',
      'expires_in': 300,
      'token_type': 'Bearer',
    };
    adapter = WebAppAuthAdapter(
      http: http,
      location: location,
      session: session,
      random: Random(7),
      now: () => DateTime.utc(2026, 1, 1),
      policy: const ReleaseTransportPolicy(),
    );
  });

  int tokenCalls() => http.calls.where((c) => c.form != null).length;

  /// Runs the start phase and returns the authorize URL's parameters.
  Future<Map<String, String>> start() async {
    // The future never completes (the page unloads); do not await it.
    adapter.authorizeAndExchangeCode(req());
    for (var i = 0; i < 200 && location.assigned.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(location.assigned, hasLength(1));
    return Uri.parse(location.assigned.single).queryParameters;
  }

  test('W1 pkce: RFC 7636 appendix B vector and generated verifier shape', () {
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    final bytes = List<int>.generate(64, (i) => i * 3);
    final v = base64UrlNoPad(bytes);
    expect(v.length, inInclusiveRange(43, 128));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v), isTrue);
  });

  test('W2 start: authorize URL, pending stored, redirect issued, no token'
      ' call', () async {
    final q = await start();
    expect(location.assigned.single, startsWith('$_issuer/protocol/'));
    expect(q['client_id'], 'cid');
    expect(q['redirect_uri'], _redirect);
    expect(q['response_type'], 'code');
    expect(q['code_challenge_method'], 'S256');
    expect(q['scope'], 'openid profile email');
    expect(q['state'], isNotEmpty);
    expect(q['nonce'], isNotEmpty);
    final pending =
        jsonDecode(session.m[kWebPendingKey]!) as Map<String, dynamic>;
    expect(pending['state'], q['state']);
    expect(pkceChallenge(pending['verifier'] as String), q['code_challenge']);
    expect(pending.containsKey('slug'), isFalse);
    expect(tokenCalls(), 0);
  });

  test('W2 start: off-origin or foreign-issuer discovery is refused', () async {
    http.discovery['token_endpoint'] = 'https://evil.example/token';
    await expectLater(
      adapter.authorizeAndExchangeCode(req()),
      throwsStateError,
    );
    http.discovery['token_endpoint'] = '$_issuer/t';
    http.discovery['issuer'] = 'https://idp.example/realms/other';
    await expectLater(
      adapter.authorizeAndExchangeCode(req()),
      throwsStateError,
    );
    http.discovery['issuer'] = _issuer;
    http.discovery['authorization_endpoint'] = 'http://idp.example/auth';
    await expectLater(
      adapter.authorizeAndExchangeCode(req()),
      throwsStateError,
    );
    expect(location.assigned, isEmpty);
  });

  group('callback', () {
    late Map<String, String> q;
    setUp(() async {
      q = await start();
      location.assigned.clear();
    });

    void callback(Map<String, String> params) {
      location.current = Uri.parse(_redirect).replace(queryParameters: params);
    }

    test(
      'W3 rejects: state mismatch, no token call, pending consumed',
      () async {
        callback({'code': 'c', 'state': 'forged'});
        await expectLater(
          adapter.authorizeAndExchangeCode(req()),
          throwsStateError,
        );
        expect(tokenCalls(), 0);
        expect(session.m.containsKey(kWebPendingKey), isFalse);
      },
    );

    test('W3 rejects: missing pending', () async {
      session.m.clear();
      callback({'code': 'c', 'state': q['state']!});
      await expectLater(
        adapter.authorizeAndExchangeCode(req()),
        throwsStateError,
      );
      expect(tokenCalls(), 0);
    });

    test('W3 rejects: pending from another issuer or client', () async {
      callback({'code': 'c', 'state': q['state']!});
      await expectLater(
        adapter.authorizeAndExchangeCode(
          req(issuer: 'https://idp.example/realms/b'),
        ),
        throwsStateError,
      );
      expect(tokenCalls(), 0);
    });

    test(
      'W3 rejects: IdP error; access_denied is a cancellation (null)',
      () async {
        callback({'error': 'server_error', 'state': q['state']!});
        await expectLater(
          adapter.authorizeAndExchangeCode(req()),
          throwsStateError,
        );
        // fresh start again for the cancellation case
        location.current = Uri.parse(_redirect);
        final q2 = await start();
        callback({'error': 'access_denied', 'state': q2['state']!});
        expect(await adapter.authorizeAndExchangeCode(req()), isNull);
        expect(tokenCalls(), 0);
      },
    );

    test('W3 rejects: nonce mismatch in the id_token', () async {
      http.tokenBody['id_token'] = _jwt({'nonce': 'other'});
      callback({'code': 'c', 'state': q['state']!});
      await expectLater(
        adapter.authorizeAndExchangeCode(req()),
        throwsStateError,
      );
    });

    test(
      'W4 ok: exchange carries verifier + redirect_uri; single use',
      () async {
        http.tokenBody['id_token'] = _jwt({'nonce': q['nonce']});
        callback({'code': 'the-code', 'state': q['state']!});
        expect(
          peekPending(location, session),
          isNull,
          reason: 'no slug remembered yet',
        );
        session.setItem(kWebSlugKey, 'acme');
        expect(peekPending(location, session)?.slug, 'acme');

        final res = await adapter.authorizeAndExchangeCode(req());
        expect(res!.accessToken, 'at');
        expect(res.refreshToken, 'rt');
        expect(
          res.accessTokenExpirationDateTime,
          DateTime.utc(2026, 1, 1).add(const Duration(seconds: 300)),
        );
        final call = http.calls.last;
        expect(call.url.toString(), '$_issuer/protocol/openid-connect/token');
        final form = call.form!;
        expect(form['grant_type'], 'authorization_code');
        expect(form['code'], 'the-code');
        expect(form['redirect_uri'], _redirect);
        expect(form['client_id'], 'cid');
        expect(pkceChallenge(form['code_verifier']!), q['code_challenge']);
        expect(session.m, isEmpty);
        expect(location.replaced.single, _redirect);
        expect(peekPending(location, session), isNull);

        // A replay of the same callback finds no pending record.
        callback({'code': 'the-code', 'state': q['state']!});
        await expectLater(
          adapter.authorizeAndExchangeCode(req()),
          throwsStateError,
        );
        expect(tokenCalls(), 1);
      },
    );
  });

  test(
    'W5 refresh: grant sent, failure throws, off-origin endpoint refused',
    () async {
      final res = await adapter.refresh(
        TokenRequest(
          'cid',
          kOidcRedirectUrl,
          issuer: _issuer,
          refreshToken: 'r0',
        ),
      );
      expect(res.accessToken, 'at');
      final form = http.calls.last.form!;
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], 'r0');

      http.tokenBody = {'error': 'invalid_grant'};
      await expectLater(
        adapter.refresh(
          TokenRequest(
            'cid',
            kOidcRedirectUrl,
            issuer: _issuer,
            refreshToken: 'r0',
          ),
        ),
        throwsStateError,
      );

      http.discovery['token_endpoint'] = 'https://evil.example/token';
      final before = tokenCalls();
      await expectLater(
        adapter.refresh(
          TokenRequest(
            'cid',
            kOidcRedirectUrl,
            issuer: _issuer,
            refreshToken: 'r0',
          ),
        ),
        throwsStateError,
      );
      expect(tokenCalls(), before);
    },
  );

  group('S1 web token store', () {
    test('tokens only in memory, pointer only in the pointer store', () async {
      final tokens = MemoryKv();
      final storage = MapStorage();
      final store = TenantTokenStore.withBackends(
        tokens: tokens,
        pointer: WebPointerKv(storage),
      );
      await store.store(
        'https://idp/r',
        const TokenSet(
          accessToken: 'A',
          refreshToken: 'R',
          idToken: null,
          accessTokenExpiration: null,
        ),
      );
      await writeLastActiveTenant(
        store,
        const LastActiveTenantPointer(realmUrl: 'https://idp/r', slug: 's'),
      );
      expect((await store.read('https://idp/r'))?.accessToken, 'A');
      expect(storage.m.keys, [kWebPointerKey]);
      expect(storage.m.values.join(), isNot(contains('A"')));
      expect((await readLastActiveTenant(store))?.slug, 's');
      await store.delete('https://idp/r');
      await clearLastActiveTenant(store);
      expect(await store.read('https://idp/r'), isNull);
      expect(storage.m, isEmpty);
    });

    test('WebPointerKv refuses any other key', () async {
      final kv = WebPointerKv(MapStorage());
      await expectLater(
        kv.write('letflow.tenant_tokens.x', 'v'),
        throwsArgumentError,
      );
      await expectLater(kv.read('other'), throwsArgumentError);
      await expectLater(kv.delete('other'), throwsArgumentError);
    });
  });
}
