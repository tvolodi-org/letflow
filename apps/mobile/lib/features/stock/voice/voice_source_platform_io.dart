/// The native recorder (Android, iOS): see `voice_source_platform.dart`.
library;

import 'package_recorder_port.dart';
import 'record_voice_source.dart';
import 'voice_source.dart';

VoiceSource createVoiceSource() => RecordVoiceSource(PackageRecorderPort());
