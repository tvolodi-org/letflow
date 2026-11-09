/** Access sets of the four role screens of the sidebar walk (T-1522). The role-named fixtures in auth/access/fixtures.ts
 *  predate the modules, so the module atoms a tenant administrator holds are added here; the test
 *  navVisibility.test.ts (N9) pins every set here to priv/permission_matrix/effective.golden. */
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'

export const MODULE_ATOMS_TENANT_ADMIN = [
  'AssetsCardWrite', 'AssetsPost', 'AssetsRead', 'AssetsReconcile', 'AssetsReverse', 'CatalogLotsWrite', 'CodesRead', 'CodesWrite',
  'DocumentHold', 'DocumentsRetentionManage', 'EntitiesExtensionsManage', 'EntitiesViewsManage', 'ExamGradingRead', 'ExamGradingWrite',
  'IntegrationMappingsManage', 'LabelsManage', 'LocationsWrite', 'NotificationTemplatesManage', 'NumberSequencesManage',
  'OrgEmployeesWrite', 'OrgStructureWrite', 'ProcurementLineRecord', 'ProcurementRequestDecide', 'ProcurementRequestRead',
  'ProcurementRequestWrite', 'ScheduledJobsManage', 'StockCountOrder', 'StockCountRecord', 'StockPost', 'StockRead', 'StockReconcile',
  'StockReverse',
]

export const NAV_ROLE_PERMISSIONS = {
  admin: [...ACCESS_FIXTURES.tenantAdmin.permissions, ...MODULE_ATOMS_TENANT_ADMIN, 'MyPreferencesSet'],
  storekeeper: [...ACCESS_FIXTURES.storekeeper.permissions, 'MyPreferencesSet'],
  worker: [...ACCESS_FIXTURES.taskWorker.permissions, 'MyPreferencesSet'],
  /** A custom role: the task atoms only. Not in the matrix, so no golden check beyond "every atom exists". */
  scoped: ['TasksRead', 'TasksComplete', 'EntitiesQuery'],
} as const

export type NavRole = keyof typeof NAV_ROLE_PERMISSIONS

/** Module ids the tenant of the role screens has installed (all registered modules). */
export const ALL_MODULE_IDS = ['exam', 'org', 'locations', 'codes', 'catalog_items', 'stock', 'assets']
