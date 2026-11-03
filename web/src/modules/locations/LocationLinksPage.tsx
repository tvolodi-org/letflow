/** LocationLinksPage — GH 3607 / REQ-671. Links between org units and locations, seen by org unit or by location:
 *  list the links of the chosen end, link another, unlink. Org units are read through the generic query route
 *  (no org module code is imported). A 403 on the org unit read is an error state of the page. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { EmptyState } from '@/components/ui/EmptyState'
import { FormActions, FormRow, FormSection } from '@/components/ui/FormSection'
import { Select } from '@/components/ui/Select'
import { Tabs } from '@/components/ui/Tabs'
import { useToast } from '@/hooks/useToast'
import type { EntityRecord } from '@/types/api'
import { ACTIVE_TRUE, DELETED_FALSE, locationsApi, type LinkBody } from './locations.api'
import { LocationsIntlProvider } from './LocationsIntlProvider'
import { LocationsErrorAlert, LocationsShell, labelOf, useLocationRows } from './LocationsShell'
import { LINK, LOCATION_NODE, ORG_UNIT, isActive, textOf, treeOptions } from './locationsModel'
import { useLocationsWrite } from './useLocationsWrite'

type Cmd = { op: 'link' | 'unlink'; body: LinkBody }

function run(cmd: Cmd, key: string) {
  return cmd.op === 'link' ? locationsApi.linkUnit(cmd.body, key) : locationsApi.unlinkUnit(cmd.body, key)
}

type Mode = 'unit' | 'location'

function LinksInner({ initialUnitId }: { initialUnitId?: string }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const toast = useToast()
  const [mode, setMode] = useState<Mode>('unit')
  const [unitId, setUnitId] = useState(initialUnitId ?? '')
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
    if (result === 'ok') {
      if (op === 'link') setAddId('')
      toast.success(t(op === 'link' ? 'locations.toast.linked' : 'locations.toast.unlinked'))
    }
  }

  function switchMode(next: Mode) {
    write.clearError()
    setMode(next)
    setAddId('')
  }

  const otherOf = (l: EntityRecord) => otherRows.find((r) => r.record_id === textOf(l, otherKey))
  const columns: DataTableColumn<EntityRecord>[] = [
    { key: 'code', label: t('locations.common.code'), mono: true, render: (l) => textOf(otherOf(l) ?? l, 'code') || dash },
    { key: 'name', label: t('locations.common.name'), render: (l) => labelOf(otherRows, textOf(l, otherKey), dash) },
    ...(mode === 'unit'
      ? [{ key: 'address', label: t('locations.common.address'), mono: true, render: (l: EntityRecord) => textOf(otherOf(l) ?? l, 'address') || dash }]
      : []),
    {
      key: 'actions',
      label: t('locations.common.actions'),
      render: (l) => (
        <Button variant="danger" size="sm" disabled={write.isPending} onClick={() => void submit('unlink', textOf(l, otherKey))}>
          {t('locations.common.unlink')}
        </Button>
      ),
    },
  ]

  return (
    <LocationsShell title={t('locations.links.title')} eyebrow={t('locations.links.eyebrow')} lede={t('locations.links.lede')} queries={[units, locations, links]}>
      <LocationsErrorAlert error={write.error} link />
      <div className="lf-card">
        <div className="lf-card__body">
          <Tabs
            aria-label={t('locations.links.modeLabel')}
            selected={mode}
            onChange={(id) => switchMode(id as Mode)}
            items={[
              { id: 'unit', label: t('locations.links.modeUnit') },
              { id: 'location', label: t('locations.links.modeLocation') },
            ]}
          />
          <FormSection>
            <FormRow>
              {mode === 'unit' ? (
                <Select
                  name="unit"
                  label={t('locations.links.pickUnit')}
                  width="l"
                  value={unitId}
                  options={treeOptions(unitRows, 'parent')}
                  placeholder={t('locations.common.choose')}
                  onChange={(v) => {
                    setUnitId(v)
                    setAddId('')
                  }}
                />
              ) : (
                <Select
                  name="location"
                  label={t('locations.links.pickLocation')}
                  width="l"
                  value={locationId}
                  options={treeOptions(locationRows, 'parent_id')}
                  placeholder={t('locations.common.choose')}
                  onChange={(v) => {
                    setLocationId(v)
                    setAddId('')
                  }}
                />
              )}
            </FormRow>
          </FormSection>
          {chosen === '' ? (
            <EmptyState title={t(mode === 'unit' ? 'locations.links.chooseUnitHint' : 'locations.links.chooseLocationHint')} />
          ) : (
            <>
              <FormSection title={t(mode === 'unit' ? 'locations.links.linkedLocations' : 'locations.links.linkedUnits')}>
                <DataTable
                  columns={columns}
                  data={linkRows}
                  getRowId={(l) => l.record_id}
                  emptyMessage={t('locations.links.nothingLinked')}
                />
              </FormSection>
              <FormSection>
                <FormRow>
                  <Select
                    name="add"
                    label={t(mode === 'unit' ? 'locations.links.addLocation' : 'locations.links.addUnit')}
                    width="l"
                    value={addId}
                    options={pickable}
                    placeholder={t('locations.common.choose')}
                    onChange={setAddId}
                  />
                </FormRow>
                <FormActions
                  primary={
                    <Button
                      variant="primary"
                      size="md"
                      loading={write.isPending}
                      disabled={write.isPending || addId === '' || !otherRows.some((r) => r.record_id === addId && isActive(r))}
                      onClick={() => void submit('link', addId)}
                      data-testid="link-add"
                    >
                      {t('locations.common.link')}
                    </Button>
                  }
                />
              </FormSection>
            </>
          )}
        </div>
      </div>
    </LocationsShell>
  )
}

/** `initialUnitId` shows the links of an org unit at first render (the screen harness uses it). */
export default function LocationLinksPage({ initialUnitId }: { initialUnitId?: string } = {}) {
  return (
    <LocationsIntlProvider>
      <LinksInner initialUnitId={initialUnitId} />
    </LocationsIntlProvider>
  )
}
