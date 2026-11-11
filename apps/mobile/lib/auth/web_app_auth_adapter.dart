/// Web OIDC sign-in for the PWA (PWA M2, D-112): Authorization Code + PKCE
/// (S256) by full-page redirect, own implementation because `flutter_appauth`
/// has no web support.
///
/// Platform-neutral on purpose (Dio + `package:crypto` + two seams) so the
/// whole flow runs under `flutter test`; the browser-backed seams are in
/// `web_browser.dart`.
///
/// Two phases, because a redirect cannot return into the page that started it:
/// 1. start: discover, create verifier/state/nonce, keep them as a one-use
///    pending record in sessionStorage, navigate to the authorize endpoint;
/// 2. callback: the page reloads with `?code&state`; the pending record is
///    removed first, the query stripped, then the code is exchanged.
///
/// Tokens are returned to the caller and never written anywhere by this
/// class. Web token storage decision: `apps/mobile/README.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_appauth/flutter_appauth.dart';

import '../api/transport_policy.dart';
import 'auth.dart' show AppAuthAdapter;
import 'app_auth_platform_types.dart';
import 'kv_store.dart';

const String kWebPendingKey = 'letflow.oidc.pending';
const String kWebSlugKey = 'letflow.oidc.slug';

/// Page location seam.
abstract interface class WebLocation {
  /// Current page URL.
  Uri get current;

  /// `origin + base path` of the page (e.g. `https://host/mobile/`): the
  /// redirect URI. Derived from the page, never from tenant data.
  String get redirectUri;

  void assign(String url);

  /// Replace the current history entry's URL (no navigation).
  void replaceState(String url);
}

/// The URL carries an authorization response (`code`+`state`, or `error`).
bool isOidcCallback(Uri url) {
  final q = url.queryParameters;
  return (q.containsKey('code') && q.containsKey('state')) ||
      q.containsKey('error');
}

String _stripQuery(Uri url) {
  final s = url.toString();
  final i = s.indexOf(RegExp(r'[?#]'));
  return i < 0 ? s : s.substring(0, i);
}

/// Pure read of a waiting sign-in (see `peekWebPendingSignIn`).
WebPendingSignIn? peekPending(WebLocation location, StringStorage session) {
  final q = location.current.queryParameters;
  if (!isOidcCallback(location.current)) return null;
  final raw = session.getItem(kWebPendingKey);
  final slug = session.getItem(kWebSlugKey);
  if (raw == null || slug == null || slug.isEmpty) return null;
  try {
    final pending = jsonDecode(raw) as Map<String, dynamic>;
    final state = pending['state'];
    if (state is String && state == q['state']) {
      return WebPendingSignIn(slug: slug, state: state);
    }
  } catch (_) {}
  return null;
}

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// RFC 7636 S256 challenge.
String pkceChallenge(String verifier) =>
    base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

/// An endpoint must be a policy-allowed URL on the issuer's origin.
Uri checkIssuerEndpoint(TransportPolicy policy, Object? value, Uri issuerUri) {
  if (value is! String) throw StateError('missing endpoint');
  final u = Uri.parse(value);
  if (!policy.isUrlAllowed(u) ||
      u.scheme != issuerUri.scheme ||
      u.host != issuerUri.host ||
      u.port != issuerUri.port) {
    throw StateError('endpoint off the issuer origin');
  }
  return u;
}

/// Form POST that returns only the HTTP status (RFC 7009 revocation). A
/// separate seam so [OidcHttp] stays unchanged.
abstract interface class OidcRevocationHttp {
  Future<int> postFormStatus(Uri url, Map<String, String> form);
}

/// Revokes a refresh token at the IdP's `revocation_endpoint` (RFC 7009,
/// public client: `client_id`, no secret, no admin API). Throws on any
/// failure; the caller treats that as "revocation failed" and still deletes
/// the local record.
class OidcRevoker {
  OidcRevoker({
    required OidcHttp discovery,
    required OidcRevocationHttp post,
    TransportPolicy? policy,
  }) : _discovery = discovery,
       _post = post,
       _policy = policy ?? transportPolicyFor();

  final OidcHttp _discovery;
  final OidcRevocationHttp _post;
  final TransportPolicy _policy;

  Future<void> revoke(
    String issuer,
    String clientId,
    String refreshToken,
  ) async {
    final issuerUri = Uri.parse(issuer);
    if (!_policy.isUrlAllowed(issuerUri)) {
      throw StateError('issuer not allowed by transport policy');
    }
    final base = issuer.endsWith('/') ? issuer : '$issuer/';
    final doc = await _discovery.getJson(
      Uri.parse('$base.well-known/openid-configuration'),
    );
    String strip(String s) =>
        s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    if (doc['issuer'] is! String ||
        strip(doc['issuer'] as String) != strip(issuer)) {
      throw StateError('discovery issuer mismatch');
    }
    final endpoint = checkIssuerEndpoint(
      _policy,
      doc['revocation_endpoint'],
      issuerUri,
    );
    final status = await _post.postFormStatus(endpoint, {
      'token': refreshToken,
      'token_type_hint': 'refresh_token',
      'client_id': clientId,
    });
    if (status < 200 || status >= 300) {
      throw StateError('revocation answered $status');
    }
  }
}

class WebAppAuthAdapter implements AppAuthAdapter {
  WebAppAuthAdapter({
    required OidcHttp http,
    required WebLocation location,
    required StringStorage session,
    Random? random,
    DateTime Function()? now,
    TransportPolicy? policy,
  }) : _http = http,
       _location = location,
       _session = session,
       _random = random ?? Random.secure(),
       _now = now ?? DateTime.now,
       _policy = policy ?? transportPolicyFor();

  final OidcHttp _http;
  final WebLocation _location;
  final StringStorage _session;
  final Random _random;
  final DateTime Function() _now;
  final TransportPolicy _policy;

  String _randomToken([int bytes = 32]) =>
      base64UrlNoPad(List<int>.generate(bytes, (_) => _random.nextInt(256)));

  @override
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) {
    if (isOidcCallback(_location.current)) return _finishCallback(request);
    return _start(request);
  }

  Future<Map<String, dynamic>> _discover(String issuer) async {
    final issuerUri = Uri.parse(issuer);
    if (!_policy.isUrlAllowed(issuerUri)) {
      throw StateError('issuer not allowed by transport policy');
    }
    final base = issuer.endsWith('/') ? issuer : '$issuer/';
    final map = await _http.getJson(
      Uri.parse('$base.well-known/openid-configuration'),
    );
    String strip(String s) =>
        s.endsWith('/') ? s.substring(0, s.length - 1) : s;
    if (map['issuer'] is! String ||
        strip(map['issuer'] as String) != strip(issuer)) {
      throw StateError('discovery issuer mismatch');
    }
    for (final k in ['authorization_endpoint', 'token_endpoint']) {
      _checkEndpoint(map[k], issuerUri);
    }
    return map;
  }

  /// An endpoint must be a policy-allowed URL on the issuer's origin.
  Uri _checkEndpoint(Object? value, Uri issuerUri) =>
      checkIssuerEndpoint(_policy, value, issuerUri);

  Future<AuthorizationTokenResponse?> _start(
    AuthorizationTokenRequest request,
  ) async {
    final issuer = request.issuer;
    if (issuer == null) throw StateError('issuer required');
    final doc = await _discover(issuer);
    final verifier = _randomToken(64);
    final state = _randomToken();
    final nonce = _randomToken();
    final redirectUri = _location.redirectUri;
    final authorize = Uri.parse(doc['authorization_endpoint'] as String);
    _session.setItem(
      kWebPendingKey,
      jsonEncode({
        'state': state,
        'verifier': verifier,
        'nonce': nonce,
        'issuer': issuer,
        'clientId': request.clientId,
        'redirectUri': redirectUri,
        'tokenEndpoint': doc['token_endpoint'],
      }),
    );
    final url = authorize.replace(
      queryParameters: {
        ...authorize.queryParameters,
        'response_type': 'code',
        'client_id': request.clientId,
        'redirect_uri': redirectUri,
        'scope': (request.scopes ?? const <String>[]).join(' '),
        'state': state,
        'nonce': nonce,
        'code_challenge': pkceChallenge(verifier),
        'code_challenge_method': 'S256',
      },
    );
    _location.assign(url.toString());
    // The page unloads; this future must not complete.
    return Completer<AuthorizationTokenResponse?>().future;
  }

  Future<AuthorizationTokenResponse?> _finishCallback(
    AuthorizationTokenRequest request,
  ) async {
    final q = _location.current.queryParameters;
    final raw = _session.getItem(kWebPendingKey);
    // Single use: remove before anything else, then strip the query so Back
    // or a reload cannot replay the callback.
    _session.removeItem(kWebPendingKey);
    _session.removeItem(kWebSlugKey);
    _location.replaceState(_stripQuery(_location.current));

    if (raw == null) throw StateError('no pending sign-in');
    final Map<String, dynamic> pending;
    try {
      pending = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw StateError('corrupt pending sign-in');
    }
    if (pending['state'] is! String || pending['state'] != q['state']) {
      throw StateError('state mismatch');
    }
    if (pending['issuer'] != request.issuer ||
        pending['clientId'] != request.clientId) {
      throw StateError('pending sign-in belongs to another tenant');
    }
    final error = q['error'];
    if (error != null) {
      if (error == 'access_denied') return null;
      throw StateError('authorization error: $error');
    }
    final code = q['code'];
    if (code == null || code.isEmpty) throw StateError('no code');

    final tokenEndpoint = _checkEndpoint(
      pending['tokenEndpoint'],
      Uri.parse(request.issuer!),
    );
    final body = await _postToken(tokenEndpoint, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': pending['redirectUri'] as String,
      'client_id': request.clientId,
      'code_verifier': pending['verifier'] as String,
    });

    final idToken = body['id_token'];
    if (idToken is String) {
      final claims = _jwtClaims(idToken);
      final nonce = claims?['nonce'];
      if (nonce != null && nonce != pending['nonce']) {
        throw StateError('nonce mismatch');
      }
    }
    return AuthorizationTokenResponse(
      body['access_token'] as String?,
      body['refresh_token'] as String?,
      _expiry(body),
      idToken is String ? idToken : null,
      body['token_type'] as String?,
      null,
      null,
      null,
    );
  }

  DateTime? _expiry(Map<String, dynamic> body) {
    final e = body['expires_in'];
    return e is num ? _now().add(Duration(seconds: e.toInt())) : null;
  }

  Map<String, dynamic>? _jwtClaims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final m = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _postToken(
    Uri endpoint,
    Map<String, String> form,
  ) async {
    final body = await _http.postForm(endpoint, form);
    if (body['access_token'] is! String) throw StateError('no access_token');
    return body;
  }

  @override
  Future<TokenResponse> refresh(TokenRequest request) async {
    final issuer = request.issuer;
    final refreshToken = request.refreshToken;
    if (issuer == null || refreshToken == null) {
      throw StateError('issuer and refresh token required');
    }
    final doc = await _discover(issuer);
    final body = await _postToken(Uri.parse(doc['token_endpoint'] as String), {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': request.clientId,
    });
    final id = body['id_token'];
    return TokenResponse(
      body['access_token'] as String?,
      body['refresh_token'] as String?,
      _expiry(body),
      id is String ? id : null,
      body['token_type'] as String?,
      null,
      null,
    );
  }
}
