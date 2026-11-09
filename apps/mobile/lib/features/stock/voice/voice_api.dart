/// The two stock voice routes (REQ-741) as the phone calls them. Both only
/// return a draft; the phone never posts anything through them.
library;

import 'dart:typed_data';

import '../../../api/api_client.dart';
import '../count_api.dart' show kStockBase;
import 'voice_codec.dart';
import 'voice_models.dart';

const String kVoiceDraftPath = '$kStockBase/voice/draft';
const String kVoiceDraftTextPath = '$kStockBase/voice/draft-text';

class StockVoiceApi {
  StockVoiceApi(this._client);

  final PostCapableHttpGateway _client;

  /// The file name and content type follow the bytes (MP4 from a phone or
  /// Safari, WebM from Chrome); the server sniffs the bytes itself.
  Future<VoiceDraft> draftAudio(Uint8List bytes, String lang) async {
    final format = audioUploadFormat(bytes);
    final response = await _client.post(
      kVoiceDraftPath,
      data: buildFileUploadFormData(
        bytes: bytes,
        fileName: format.fileName,
        contentType: format.contentType,
        partName: 'audio',
        fields: {'lang': lang},
      ),
    );
    return VoiceDraft.fromJson(response.data);
  }

  /// [text] is sent unchanged (no trim, no case change).
  Future<VoiceDraft> draftText(String text, String lang) async {
    final response = await _client.post(
      kVoiceDraftTextPath,
      data: {'text': text, 'lang': lang},
    );
    return VoiceDraft.fromJson(response.data);
  }
}
