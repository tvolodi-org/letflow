/// Records or takes a typed phrase, sends it to the voice route and hands the
/// answered draft to the screen (REQ-747). Independent of the count and form
/// controllers: a voice failure never blocks typing or scanning. It never
/// saves, counts or posts; audio, transcript and draft live in memory only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../api/api_error.dart';
import '../../../renderers/renderer_state.dart';
import '../count_models.dart';
import 'voice_api.dart';
import 'voice_failure.dart';
import 'voice_language.dart';
import 'voice_models.dart';
import 'voice_source.dart';

enum VoicePhase { idle, recording, sending }

class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.source,
    required this.api,
    required this.onDraft,
    this.maxRecording = const Duration(seconds: 60),
    String? initialLang,
  }) : lang = initialLang ?? appVoiceLang();

  final VoiceSource source;
  final StockVoiceApi api;
  final void Function(VoiceDraft) onDraft;
  final Duration maxRecording;

  VoicePhase phase = VoicePhase.idle;

  /// `ru` or `kk`; null until the user chooses (English app language).
  String? lang;
  String? messageKey;
  RendererState<Object?>? failure;
  String? transcript;
  String? _lastText;
  Timer? _cap;
  bool _disposed = false;

  bool get busy => phase == VoicePhase.sending;
  bool get recording => phase == VoicePhase.recording;

  void chooseLang(String l) {
    if (l != 'ru' && l != 'kk') return;
    lang = l;
    _notify();
  }

  Future<void> startRecording() async {
    if (phase != VoicePhase.idle || lang == null) return;
    _clear();
    final started = await source.start();
    if (_disposed) {
      unawaited(source.cancel());
      return;
    }
    switch (started) {
      case VoiceStarted():
        phase = VoicePhase.recording;
        _cap = Timer(maxRecording, () => unawaited(stopAndSend()));
      case VoicePermissionDenied():
        messageKey = 'stock.voice.mic.denied';
      case VoiceUnavailable():
        messageKey = 'stock.voice.mic.unavailable';
    }
    _notify();
  }

  Future<void> stopAndSend() async {
    if (phase != VoicePhase.recording) return;
    _cap?.cancel();
    final l = lang;
    final bytes = await source.stop();
    if (_disposed) return;
    if (bytes == null || l == null) {
      phase = VoicePhase.idle;
      messageKey = 'stock.voice.mic.unavailable';
      _notify();
      return;
    }
    phase = VoicePhase.sending;
    _notify();
    await _send(() => api.draftAudio(bytes, l));
  }

  Future<void> cancelRecording() async {
    if (phase != VoicePhase.recording) return;
    _cap?.cancel();
    phase = VoicePhase.idle;
    _notify();
    await source.cancel();
  }

  /// [text] is sent unchanged; only the empty string is refused here.
  Future<void> sendText(String text) async {
    final l = lang;
    if (text.isEmpty || l == null || phase != VoicePhase.idle) return;
    _lastText = text;
    _clear();
    phase = VoicePhase.sending;
    _notify();
    await _send(() => api.draftText(text, l));
  }

  /// Re-runs the last typed phrase (an audio retry means recording again).
  Future<void> retry() async {
    final t = _lastText;
    if (t != null) await sendText(t);
  }

  void _clear() {
    messageKey = null;
    failure = null;
    transcript = null;
  }

  Future<void> _send(Future<VoiceDraft> Function() call) async {
    VoiceDraft? draft;
    try {
      draft = await call();
    } on ApiError catch (e) {
      if (_disposed) return;
      switch (mapVoiceError(e)) {
        case VoiceMessage(:final key):
          messageKey = key;
        case VoiceState(:final state):
          failure = state;
      }
    } on MalformedStockAnswer {
      if (_disposed) return;
      failure = const RendererFetchFailure();
    }
    if (_disposed) return;
    phase = VoicePhase.idle;
    if (draft != null) {
      transcript = draft.transcript;
      if (draft.modelOff) {
        messageKey = 'stock.voice.modelOff';
      } else {
        onDraft(draft);
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cap?.cancel();
    if (phase == VoicePhase.recording) unawaited(source.cancel());
    super.dispose();
  }
}
