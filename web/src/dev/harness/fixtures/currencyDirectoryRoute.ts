/** Harness route of the currency directory (REQ-828): GET /api/v1/currencies, tenant currency KZT. Invented data. */
import type { FixtureRoute } from '../types'

export const currenciesRoute: FixtureRoute = {
  match: (path, method) => path === '/api/v1/currencies' && method === 'GET',
  reply: () => ({
    status: 200,
    body: {
      tenant_currency: 'KZT',
      currencies: [
        { code: 'KZT', numeric_code: '398', minor_units: 2, names: { en: 'Tenge', ru: 'Тенге', kk: 'Теңге' }, active: true },
        { code: 'USD', numeric_code: '840', minor_units: 2, names: { en: 'US dollar', ru: 'Доллар США', kk: 'АҚШ доллары' }, active: true },
      ],
    },
  }),
}
