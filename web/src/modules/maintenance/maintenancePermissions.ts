/** The permission atoms of the maintenance module screens (REQ-894 / REQ-896; screens REQ-898). The server stays
 *  the authority: the SPA only hides what the user's access does not list. */
/** The task inbox permission: the only one My maintenance orders needs. */
export const TASKS_READ = 'TasksRead'
export const MAINTENANCE_READ = 'MaintenanceRead'
/** Report a problem (create a work request). */
export const MAINTENANCE_REQUEST_CREATE = 'MaintenanceRequestCreate'
/** Plan the work: reject a request, make a work order. */
export const MAINTENANCE_ORDER_MANAGE = 'MaintenanceOrderManage'
