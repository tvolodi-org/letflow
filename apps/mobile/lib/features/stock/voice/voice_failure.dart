/// Which voice part failed, and what the screen says (REQ-747 criterion 5).
/// The texts name the part, never the provider or a raw error.
library;

import '../../../api/api_error.dart';
import '../../../renderers/renderer_state.dart';

sealed class VoiceFailure {
  const VoiceFailure();
}

class VoiceMessage extends VoiceFailure {
  const VoiceMessage(this.key);
  final String key;
}

class VoiceState extends VoiceFailure {
  const VoiceState(this.state);
  final RendererState<Object?> state;
}

VoiceFailure mapVoiceError(ApiError e) {
  switch (e) {
    case ServerError(:final lastStatusCode, :final source):
      if (lastStatusCode == 413) {
        return const VoiceMessage('stock.voice.tooLarge');
      }
      if (lastStatusCode == 415) {
        return const VoiceMessage('stock.voice.badFormat');
      }
      final partFailure =
          lastStatusCode == 502 ||
          lastStatusCode == 503 ||
          lastStatusCode == 504;
      if (partFailure && source == 'speech') {
        return const VoiceMessage('stock.voice.speechDown');
      }
      if (partFailure && source == 'llm') {
        return const VoiceMessage('stock.voice.modelDown');
      }
    case ValidationError(:final reason):
      return VoiceMessage(
        reason == 'bad_language'
            ? 'stock.voice.badLanguage'
            : 'stock.voice.failed',
      );
    case NotFoundError():
    case ModuleNotAvailableError():
      return const VoiceMessage('stock.state.notAvailable');
    default:
      break;
  }
  return VoiceState(rendererStateForError<Object?>(e));
}
