/// The browser recorder (PWA M4): see `voice_source_platform.dart`.
library;

import 'voice_source.dart';
import 'web_recorder_port_web.dart';
import 'web_voice_source.dart';

VoiceSource createVoiceSource() => WebVoiceSource(WebRecorderPortImpl());
