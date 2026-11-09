/// Barrel of the `stock` feature module (phase D, D3s), imported only by
/// `lib/bootstrap/navigation_bootstrap.dart`.
library;

export 'documents/document_form_screen.dart' show kStockDocumentsPath;
export 'documents/offline_providers.dart'
    show offlineQueueProvider, offlineSyncProvider;
export 'stock_routes.dart' show stockRoutes, kStockHomePath;
