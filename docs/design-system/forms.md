# Form components (`web/src/components/ui/`)

Classes come from the generated `web/src/styles/components.css`; the components hold no colour, size or
font value and no inline style. Props follow `platform/NOTES.md` section 2 of the design repo.
Strings the components own (optional, unsaved changes, saving) come from `uiMessages.ts` in en, ru, kk;
pass `locale` to force one.

## Button (`Button.tsx`)
`variant` primary | secondary | danger | ghost; `size` sm | md | lg (compatibility: `sm` = design `s`,
`md`/`lg` = design `m`; `s`/`m` also accepted); `icon`; `iconOnly` + `label` (the label becomes the
accessible name); `loading` (text kept, `is-loading`, `aria-busy`, disabled); `disabled`; `pressed`
(`aria-pressed` and `is-pressed`). All previous props (`title`, `data-testid`, `onClick`) still work.
`is-pressed` has no rule in the design CSS; `base.css` gives it `paper-sunken` and `line-strong`.

## Field (`Field.tsx`)
`<Field label hint error optional width="s|m|l" readOnly disabled leadingIcon mono hideLabel><input/></Field>`.
Field gives its single child the `id`, `aria-invalid` and `aria-describedby` (hint or error). An error
replaces the hint. `readOnly` draws the dashed box. Keyboard: normal tab order, label click focuses.

## Select (`Select.tsx`)
`<Select label options={[{value,label,disabled?}]} value onChange(value) placeholder />`; takes the Field props.
Native `<select>`, so arrow keys and type-ahead are the browser's.

## Checkbox, Radio, Switch (`Checkbox.tsx`)
`label`, `checked`, `onChange(checked)`, `disabled`, `name`, `value`. Space toggles. Switch is a checkbox with
`role="switch"`. Radios sharing a `name` move with the arrow keys.

## FormSection, FormRow, FormActions (`FormSection.tsx`)
`FormSection title` groups rows; `FormRow` lays fields side by side and wraps. `FormActions primary secondary
dirty saving`: `dirty` true shows "Unsaved changes", false "No unsaved changes", undefined hides the hint;
`saving` shows "Saving…" instead (pass `loading` to the primary Button yourself).
