/** Access sets of the four role screens of the sidebar walk (T-1522). The role-named fixtures in auth/access/fixtures.ts
 *  predate the modules, so the module atoms a tenant administrator holds are added here; the test
 *  navVisibility.test.ts (N9) pins every set here to priv/permission_matrix/effective.golden. */
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'

export const MODULE_ATOMS_TENANT_ADMIN = [
  'ApprovalRulesManage', 'AssetsApprove', 'AssetsCardWrite', 'AssetsCountOrder', 'AssetsCountRecord', 'AssetsPost', 'AssetsRead', 'AssetsReconcile', 'AssetsReverse', 'CatalogLotsWrite', 'CodesRead', 'CodesWrite', 'CurrenciesManage',
  'DataExport', 'DocumentHold', 'DocumentsRetentionManage', 'EntitiesExtensionsManage', 'EntitiesRecordsImportAnyType', 'EntitiesViewsManage', 'ExamGradingRead', 'ExamGradingWrite',
  'IntegrationMappingsManage', 'LabelsManage', 'LedgerSettingsManage', 'LocationsWrite', 'MaintenanceOrderManage', 'MaintenanceRead', 'MaintenanceRequestCreate', 'NotificationTemplatesManage', 'NumberSequencesManage',
  'OfficialFormTemplatesManage', 'OrgEmployeesWrite', 'OrgStructureWrite', 'PhotosAdd', 'PhotosDelete', 'ProcurementLineRecord', 'ProcurementRequestDecide', 'ProcurementRequestRead',
  'ProcurementRequestWrite', 'ScheduledJobsManage', 'StockApprove', 'StockCountOrder', 'StockCountRecord', 'StockPost', 'StockQuickCount', 'StockRead', 'StockReconcile',
  'StockReverse', 'StockWorkbookApply', 'TasksReadAll', 'TasksReassignRouted', 'TenantSecurityManage',
]

export const NAV_ROLE_PERMISSIONS = {
  // `OutboundDestinationsManage` is a CORE atom, not a module atom (T-2597, pilot gap G14: the
  // per-tenant outbound allow-list). The matrix grants it to the tenant administrator, so the admin
  // screen carries it -- navVisibility.test.ts (N9) pins this set to the matrix, atom for atom.
  // (Role names are spelled out only in web/src/auth/access; a role name in a comment here trips
  // tests/guards/no-role-literals.spec.ts.)
  admin: [...ACCESS_FIXTURES.tenantAdmin.permissions, ...MODULE_ATOMS_TENANT_ADMIN, 'MyPreferencesSet', 'OutboundDestinationsManage'],
  storekeeper: [...ACCESS_FIXTURES.storekeeper.permissions, 'MyPreferencesSet'],
  worker: [...ACCESS_FIXTURES.taskWorker.permissions, 'MyPreferencesSet'],
  /** A custom role: the task atoms only. Not in the matrix, so no golden check beyond "every atom exists". */
  scoped: ['TasksRead', 'TasksComplete', 'EntitiesQuery'],
} as const

export type NavRole = keyof typeof NAV_ROLE_PERMISSIONS

/** Module ids the tenant of the role screens has installed (all registered modules). */
export const ALL_MODULE_IDS = ['exam', 'org', 'locations', 'codes', 'catalog_items', 'stock', 'assets', 'maintenance']
