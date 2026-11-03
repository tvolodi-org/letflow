# Frontend design system (moved)

This file used to hold the palette, typography, spacing and component conventions. It is replaced by:

- [`../design-system/README.md`](../design-system/README.md): how the platform design system reaches `web/`
  (generated `tokens.css`, `components.css`, logos).
- [`../design-system/principles.md`](../design-system/principles.md): the behaviour rules kept from the old text
  (ConfirmDialog, status visibility, PaginationControls, FilterBar, DynamicForm mapping, Toast, process canvas,
  breakpoints).
- The design repo `letflow-design`, `platform/NOTES.md`: the source of every value and the component list.

Old citations map as follows: §1, §7.3 destructive actions, §5 status, §6 process canvas, §7.4 toast, §7.6
DynamicForm, §7.7 FilterBar, §7.8 PaginationControls, §9 breakpoints are all in `principles.md`. §2 to §4 (colours,
type, spacing) and §7.1, §7.2, §7.5, §8 (Button, DataTable, JsonEditor, page layout) now live in the design repo
and in `web/src/components/ui/`. The path stays because older documents link to it.
