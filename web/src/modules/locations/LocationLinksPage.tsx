/** LocationLinksPage — GH 3607 / REQ-671. Links between org units and locations, seen by org unit or by location:
 *  list the links of the chosen end, link another, unlink. Org units are read through the generic query route
 *  (no org module code is imported). A 403 on the org unit read is an error state of the page. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import type { EntityRecord } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, locationsApi, type LinkBody } from './locations.api'
import { LocationsIntlProvider } from './LocationsIntlProvider'
import { LocationsErrorAlert, LocationsShell, SelectField, labelOf, useLocationRows } from './LocationsShell'
import { LINK, LOCATION_NODE, ORG_UNIT, isActive, textOf, treeOptions } from './locationsModel'
import { useLocationsWrite } from './useLocationsWrite'

type Cmd = { op: 'link' | 'unlink'; body: LinkBody }

function run(cmd: Cmd, key: string) {
  return cmd.op === 'link' ? locationsApi.linkUnit(cmd.body, key) : locationsApi.unlinkUnit(cmd.body, key)
}

type Mode = 'unit' | 'location'

function LinksInner() {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [mode, setMode] = useState<Mode>('unit')
  const [unitId, setUnitId] = useState('')
  const [locationId, setLocationId] = useState('')
  const [addId, setAddId] = useState('')
  const units = useLocationRows(ORG_UNIT, 'active', [DELETED_FALSE, ACTIVE_TRUE])
  const locations = useLocationRows(LOCATION_NODE, 'links-all', [DELETED_FALSE])
  const chosen = mode === 'unit' ? unitId : locationId
  const links = useLocationRows(
    LINK,
    `${mode}:${chosen}`,
    [
      DELETED_FALSE,
      ACTIVE_TRUE,
      { field: mode === 'unit' ? 'org_unit_id' : 'location_id', op: 'eq', value: chosen },
    ],
    { sortField: mode === 'unit' ? 'location_id' : 'org_unit_id', enabled: chosen !== '' },
  )
  const write = useLocationsWrite<Cmd>(run)

  const unitRows = units.data ?? []
  const locationRows = locations.data ?? []
  const linkRows = chosen !== '' ? (links.data ?? []) : []
  const dash = t('locations.common.dash')

  // the other end of every link of the chosen end
  const otherKey = mode === 'unit' ? 'location_id' : 'org_unit_id'
  const otherRows: EntityRecord[] = mode === 'unit' ? locationRows : unitRows
  const linkedIds = new Set(linkRows.map((l) => textOf(l, otherKey)))
  const pickable =
    mode === 'unit'
      ? treeOptions(locationRows, 'parent_id').filter((o) => !linkedIds.has(o.value))
      : treeOptions(unitRows, 'parent').filter((o) => !linkedIds.has(o.value))

  function bodyFor(otherId: string): LinkBody {
    return mode === 'unit' ? { org_unit_id: unitId, location_id: otherId } : { org_unit_id: otherId, location_id: locationId }
  }

  async function submit(op: Cmd['op'], otherId: string) {
    const result = await write.submit({ op, body: bodyFor(otherId) })
    if (result === 'ok' && op === 'link') setAddId('')
  }

  function switchMode(next: Mode) {
    write.clearError()
    setMode(next)
    setAddId('')
  }

  return (
    <LocationsShell title={t('locations.links.title')} queries={[units, locations, links]}>
      <LocationsErrorAlert error={write.error} link />
      <fieldset style={{ marginBottom: 'var(--space-3)' }}>
        <label style={{ display: 'block' }}>
          <input type="radio" name="links_mode" checked={mode === 'unit'} onChange={() => switchMode('unit')} />
          {t('locations.links.modeUnit')}
        </label>
        <label style={{ display: 'block' }}>
          <input type="radio" name="links_mode" checked={mode === 'location'} onChange={() => switchMode('location')} />
          {t('locations.links.modeLocation')}
        </label>
      </fieldset>
      {mode === 'unit' ? (
        <SelectField
          name="unit"
          label={t('locations.links.pickUnit')}
          value={unitId}
          options={treeOptions(unitRows, 'parent')}
          placeholder={t('locations.common.choose')}
          onChange={(v) => {
            setUnitId(v)
            setAddId('')
          }}
        />
      ) : (
        <SelectField
          name="location"
          label={t('locations.links.pickLocation')}
          value={locationId}
          options={treeOptions(locationRows, 'parent_id')}
          placeholder={t('locations.common.choose')}
          onChange={(v) => {
            setLocationId(v)
            setAddId('')
          }}
        />
      )}
      {chosen !== '' && (
        <>
          <h2>{t(mode === 'unit' ? 'locations.links.linkedLocations' : 'locations.links.linkedUnits')}</h2>
          {linkRows.length === 0 ? (
            <p>{t('locations.links.nothingLinked')}</p>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>{t('locations.common.code')}</th>
                  <th>{t('locations.common.name')}</th>
                  {mode === 'unit' && <th>{t('locations.common.address')}</th>}
                  <th>{t('locations.common.actions')}</th>
                </tr>
              </thead>
              <tbody>
                {linkRows.map((l) => {
                  const otherId = textOf(l, otherKey)
                  const other = otherRows.find((r) => r.record_id === otherId)
                  return (
                    <tr key={l.record_id} data-testid={`link-row-${otherId}`}>
                      <td>{other ? textOf(other, 'code') : dash}</td>
                      <td>{labelOf(otherRows, otherId, dash)}</td>
                      {mode === 'unit' && <td>{(other && textOf(other, 'address')) || dash}</td>}
                      <td>
                        <Button variant="danger" size="sm" disabled={write.isPending} onClick={() => void submit('unlink', otherId)}>
                          {t('locations.common.unlink')}
                        </Button>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          )}
          <SelectField
            name="add"
            label={t(mode === 'unit' ? 'locations.links.addLocation' : 'locations.links.addUnit')}
            value={addId}
            options={pickable}
            placeholder={t('locations.common.choose')}
            onChange={setAddId}
          />
          <Button
            variant="primary"
            size="md"
            disabled={write.isPending || addId === '' || !otherRows.some((r) => r.record_id === addId && isActive(r))}
            onClick={() => void submit('link', addId)}
            data-testid="link-add"
          >
            {t('locations.common.link')}
          </Button>
        </>
      )}
    </LocationsShell>
  )
}

export default function LocationLinksPage() {
  return (
    <LocationsIntlProvider>
      <LinksInner />
    </LocationsIntlProvider>
  )
}
