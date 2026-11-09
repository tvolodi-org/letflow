/// Refused versus missing microphone in a browser (PWA M4). Pure Dart: the
/// one place the decision is made, tested without a browser.
library;

enum MicAccess { granted, denied, unavailable }

/// Maps the `DOMException.name` of a failed `getUserMedia` call. Only a
/// refusal is [MicAccess.denied]; no device, a busy device, an insecure page
/// and every unknown name are [MicAccess.unavailable].
MicAccess classifyMicError(String? domExceptionName) =>
    switch (domExceptionName) {
      'NotAllowedError' ||
      'PermissionDeniedError' ||
      'SecurityError' => MicAccess.denied,
      _ => MicAccess.unavailable,
    };
