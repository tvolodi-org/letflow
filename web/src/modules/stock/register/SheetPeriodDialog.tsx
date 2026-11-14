/** SheetPeriodDialog — T-1925. The short period question before the stock balances sheet (official form Z-7) is
 *  printed: two date fields, Print and Cancel. The dates are YYYY-MM-DD strings; an invalid pair keeps Print disabled
 *  and names the field. `today` is the tenant's today (the day the server checks the future against). */
import { useEffect, useState } from 'react'
import { useIntl } from 'react-intl'
import { Dialog } from '@/components/ui/Dialog'
import { DateField } from '@/components/ui/DateField'
import { sheetPeriodError } from './stockRegisterModel'

export interface SheetPeriodDialogProps {
  open: boolean
  initialFrom: string
  initialTo: string
  today: string
  onConfirm: (from: string, to: string) => void
  onCancel: () => void
}

export function SheetPeriodDialog({ open, initialFrom, initialTo, today, onConfirm, onCancel }: SheetPeriodDialogProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [from, setFrom] = useState(initialFrom)
  const [to, setTo] = useState(initialTo)
  useEffect(() => {
    if (open) {
      setFrom(initialFrom)
      setTo(initialTo)
    }
  }, [open, initialFrom, initialTo])
  const errors = sheetPeriodError(from, to, today)
  const invalid = errors.from !== undefined || errors.to !== undefined
  return (
    <Dialog
      open={open}
      title={t('stock.balances.sheet.title')}
      confirmText={t('stock.balances.sheet.print')}
      cancelText={t('stock.balances.sheet.cancel')}
      confirmDisabled={invalid}
      onConfirm={() => onConfirm(from, to)}
      onCancel={onCancel}
      size="m"
      testId="sheet-period-dialog"
    >
      <DateField
        id="sheet-from"
        label={t('stock.balances.sheet.from')}
        value={from}
        onChange={setFrom}
        error={errors.from !== undefined ? t(errors.from) : undefined}
      />
      <DateField
        id="sheet-to"
        label={t('stock.balances.sheet.to')}
        value={to}
        onChange={setTo}
        error={errors.to !== undefined ? t(errors.to) : undefined}
      />
    </Dialog>
  )
}
