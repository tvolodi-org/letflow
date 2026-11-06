# 0082: cross-module posting lines (REQ-758, GH #3903)

Status: accepted for the Assets C15 change of kind (REQ-758; REQ-759 and REQ-760 build on it). Amends 0054 D6 (activation checks,
item 1: "the line names the stamp's module") and 0073 A2 ("static activation check" of at most two posting lines on one node), by
reference; those files are not edited.

## Problem

A change of kind (stock becomes an asset, docs/assets/change-of-kind.md) posts to two registers in one transaction: the `stock`
registration and the `assets` registration (0073 A2 allows two posting lines with different ledger ids on one node). No node can carry
both postings today, because of two refusals:

* `module_write_stamp_mismatch`: `Letflow.Definitions.ModuleWrites` accepts a `module_writes` line only when its `module` equals the
  module of the definition's ownership stamp, so a definition stamped by `assets` cannot name a handler of `stock`;
* `write_handler_ledger_missing`: Catalog rule 10 makes `posts_ledger` of a handler name a registration of the SAME manifest, so a
  handler of `assets` cannot post to the registration of `stock`.

## Options

**Option A (chosen).** Keep Catalog rule 10 and the ledger unchanged: each posting handler stays in the module that owns the
registration, so each posting is authorized by its own registration's `post` permission through `Letflow.Ledger.Authority`. A definition
stamped by module M may carry a line of module N (N is not M) only when ALL hold:

* (a) N is in the compiled manifest `depends_on` of M (direct dependencies, not transitive);
* (b) the line's handler in N resolves now and registers `posts_ledger`;
* (c) the same node carries a posting line of M itself;
* (d) N is installed in the tenant and N's installed manifest hash equals N's compiled hash (check 2 of 0054 D6 applied to N, with
  no accepted-hash tolerance: N is not the stamp).

Failing (a), (b) or (c) answers `module_write_stamp_mismatch` (the code a foreign line gets today, so nothing leaks about which condition
failed). Failing (d) answers the existing `module_write_module_not_installed` or `module_write_hash_mismatch`. Every other line of another
module keeps answering `module_write_stamp_mismatch`; a foreign non-posting handler stays refused.

**Option B (rejected).** A handler of M posts to a registration of a module in M's `depends_on`. It changes Catalog rule 10, the registry
lookup in `HandlerPost` and which module's permission applies, and puts the authority of N's register in M's handler code.

## Choice and reasons

Option A. It changes only the activation rule and the run-time owner recheck, leaves `lib/letflow/ledger/`, `lib/letflow/ledger.ex` and
`lib/letflow/modules/` untouched, and keeps one rule for who may post: the completing principal needs the `post` permission of EACH
registration, read at run time (`Authority`, unchanged). The activator gains no authority: activation proves that N is a declared,
installed dependency, not that the activator may post to N's register.

## Run-time recheck (outside the text of REQ-758)

`HandlerWrites.owner_recheck` compares a line's module hashes with the STAMP's hash, which is M's. For a line of N that is a
`hash_mismatch` on every completion, so REQ-758 criterion 4 cannot pass without a change in the run time. The call attributes now carry
`owner_module_id` (the stamp's module, set by `StepWrites`); for a line whose module differs from it, the recheck is "N is installed and
its installed hash equals its compiled hash" (N's own hashes). A call without `owner_module_id` keeps the strict stamp comparison for every
line, so a caller that does not set it cannot weaken the check. The conditions (a) to (c) are not re-evaluated at run time: the pinned
node is the activated node (the body hash binds it), and M's line is rechecked against M's hashes in the same transaction.

## Not decided here

* Transitive dependencies and cross-module lines for non-posting handlers: refused, no case needs them.
* The change of kind document and its two posting handlers: REQ-759 and REQ-760.
* How the asset leg learns the new card's record id: REQ-760's design.
