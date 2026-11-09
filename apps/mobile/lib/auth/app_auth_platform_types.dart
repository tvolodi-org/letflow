/// Types shared by both targets of `app_auth_platform.dart`.
library;

import 'package:flutter/foundation.dart';

/// A sign-in redirect that came back to this page and is waiting to be
/// finished: the tenant slug that started it and the OIDC `state`.
@immutable
class WebPendingSignIn {
  const WebPendingSignIn({required this.slug, required this.state});

  final String slug;
  final String state;
}
