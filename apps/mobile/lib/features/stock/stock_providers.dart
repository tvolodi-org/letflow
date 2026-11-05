import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show PutCapableHttpGateway;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;

/// The gateway the stock screens call through: the app's one [ApiClient].
/// Tests override it with a fake gateway.
final Provider<PutCapableHttpGateway> stockGatewayProvider =
    Provider<PutCapableHttpGateway>((ref) => ref.watch(apiClientProvider));
