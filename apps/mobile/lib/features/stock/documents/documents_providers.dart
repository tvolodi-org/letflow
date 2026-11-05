import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../api/api_client.dart' show WriteCapableHttpGateway;
import '../../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;

/// The gateway the document screens use: the app's one [ApiClient]. Tests
/// override it with a fake gateway.
final Provider<WriteCapableHttpGateway> stockGatewayProvider =
    Provider<WriteCapableHttpGateway>((ref) => ref.watch(apiClientProvider));
