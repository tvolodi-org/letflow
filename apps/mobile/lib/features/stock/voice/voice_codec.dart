/// Which audio encoder a browser recording uses, and how the bytes are
/// labelled for upload (PWA M4). Pure Dart: tested without a browser.
///
/// Chrome records Opus in WebM; Safari has no Opus recorder and records AAC
/// in MP4. The order (Opus first, then AAC-LC) is the one the Qoimeks web
/// build uses. The upload label comes from the bytes, never from the chosen
/// codec, the same way the server sniffs them (`voice_service.ex`
/// `content_type/1`).
library;

import 'dart:typed_data';

enum VoiceCodec { opus, aacLc }

/// Opus if the browser can record it, else AAC-LC, else null (no voice).
VoiceCodec? chooseVoiceCodec(Set<VoiceCodec> supported) {
  if (supported.contains(VoiceCodec.opus)) return VoiceCodec.opus;
  if (supported.contains(VoiceCodec.aacLc)) return VoiceCodec.aacLc;
  return null;
}

const List<int> _ebmlMagic = [0x1A, 0x45, 0xDF, 0xA3];
const List<int> _ftyp = [0x66, 0x74, 0x79, 0x70]; // "ftyp" at byte 4

/// `voice.webm` / `audio/webm` for an EBML (WebM) file; `voice.m4a` /
/// `audio/mp4` for an MP4 file and for anything else (the native default).
({String fileName, String contentType}) audioUploadFormat(Uint8List bytes) {
  bool at(int offset, List<int> magic) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (at(0, _ebmlMagic)) {
    return (fileName: 'voice.webm', contentType: 'audio/webm');
  }
  if (at(4, _ftyp)) return (fileName: 'voice.m4a', contentType: 'audio/mp4');
  return (fileName: 'voice.m4a', contentType: 'audio/mp4');
}
