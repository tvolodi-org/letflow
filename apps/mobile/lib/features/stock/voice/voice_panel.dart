/// The voice block shared by the count screen and the stock document forms
/// (REQ-747): a microphone button, a typed-phrase field, the language choice
/// when the app language is not Russian or Kazakh, and the messages. It only
/// reports the answered draft to [onDraft]; it saves nothing.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/api_client.dart' show PostCapableHttpGateway;
import '../../../i18n/i18n.dart';
import '../../../renderers/renderer_state.dart';
import '../../../renderers/renderer_state_view.dart';
import 'voice_api.dart';
import 'voice_controller.dart';
import 'voice_language.dart';
import 'voice_models.dart';
import 'voice_source.dart';

class VoicePanel extends ConsumerStatefulWidget {
  const VoicePanel({
    super.key,
    required this.gateway,
    required this.onDraft,
    this.maxRecording = const Duration(seconds: 60),
  });

  final PostCapableHttpGateway gateway;
  final void Function(VoiceDraft) onDraft;
  final Duration maxRecording;

  @override
  ConsumerState<VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends ConsumerState<VoicePanel> {
  late final VoiceController _c;
  final TextEditingController _typed = TextEditingController();

  @override
  void initState() {
    super.initState();
    _c = VoiceController(
      source: ref.read(voiceSourceProvider),
      api: StockVoiceApi(widget.gateway),
      onDraft: (d) => widget.onDraft(d),
      maxRecording: widget.maxRecording,
      initialLang: appVoiceLang(ref.read(voiceUiLocaleProvider)),
    )..addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c
      ..removeListener(_onChange)
      ..dispose();
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final failure = c.failure;
    final message = c.messageKey;
    final transcript = c.transcript;
    return Card(
      key: const Key('stock-voice-panel'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.lang == null) ...[
              Text(tr('stock.voice.lang.title')),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    key: const Key('stock-voice-lang-ru'),
                    label: Text(tr('stock.voice.lang.ru')),
                    selected: false,
                    onSelected: (_) => c.chooseLang('ru'),
                  ),
                  ChoiceChip(
                    key: const Key('stock-voice-lang-kk'),
                    label: Text(tr('stock.voice.lang.kk')),
                    selected: false,
                    onSelected: (_) => c.chooseLang('kk'),
                  ),
                ],
              ),
            ] else if (c.recording) ...[
              Text(
                key: const Key('stock-voice-recording'),
                tr('stock.voice.recording'),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const Key('stock-voice-stop'),
                    onPressed: () => unawaited(c.stopAndSend()),
                    child: Text(tr('stock.voice.stop')),
                  ),
                  TextButton(
                    key: const Key('stock-voice-cancel'),
                    onPressed: () => unawaited(c.cancelRecording()),
                    child: Text(tr('stock.voice.cancel')),
                  ),
                ],
              ),
            ] else
              FilledButton.icon(
                key: const Key('stock-voice-button'),
                onPressed: c.busy ? null : () => unawaited(c.startRecording()),
                icon: const Icon(Icons.mic),
                label: Text(
                  c.busy ? tr('stock.voice.sending') : tr('stock.voice.button'),
                ),
              ),
            Text(
              key: const Key('stock-voice-hint'),
              tr('stock.voice.mic.hint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextField(
              key: const Key('stock-voice-text'),
              controller: _typed,
              decoration: InputDecoration(
                hintText: tr('stock.voice.text.hint'),
              ),
            ),
            TextButton(
              key: const Key('stock-voice-text-send'),
              onPressed: c.busy || c.recording
                  ? null
                  : () => unawaited(c.sendText(_typed.text)),
              child: Text(tr('stock.voice.text.send')),
            ),
            if (message != null)
              Text(key: const Key('stock-voice-message'), tr(message)),
            if (failure != null && failure is! RendererContent<Object?>)
              SizedBox(
                height: 80,
                child: RendererStateView<Object?>(
                  state: failure,
                  onRetryBackpressure: c.retry,
                  contentBuilder: (context, _) => const SizedBox.shrink(),
                ),
              ),
            if (transcript != null && transcript.isNotEmpty)
              Text(
                key: const Key('stock-voice-transcript'),
                '${tr('stock.voice.transcript')}: $transcript',
              ),
          ],
        ),
      ),
    );
  }
}
