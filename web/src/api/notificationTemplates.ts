/** notificationTemplates — T-2600 (pilot gap G5b): the COMPILED catalogue of the registered notification
 *  templates.
 *
 *  `GET /api/v1/notification-templates/catalogue` (`lib/letflow/routers/notification_templates.ex`) is the only
 *  way to learn which template keys a notification step may name, and which placeholders each key accepts. The
 *  catalogue is compiled: there is no write route and no table, so a new template key appears in the designer
 *  without screen code.
 *
 *  It carries platform data only — a key and the NAMES of the placeholders it accepts. The tenant's own text
 *  (its override of a key) is a different route, behind the narrower `:NotificationTemplatesManage`.
 */
import { client } from './client'
import type { NotificationTemplateCatalogue } from '@/types/api'

export const notificationTemplatesApi = {
  catalogue: () => client.get<NotificationTemplateCatalogue>('/api/v1/notification-templates/catalogue'),
}
