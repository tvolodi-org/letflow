# G2 platform-call source-class table

Authority: decision 0094 (`docs/migration/decisions/0094-platform-call-authority.md`), especially (b), and the G2 decision record's option A. This is the complete class enumeration required for T-2588. A row names its behavioural test and the mechanical class test; the generated probes enumerate the compiled catalogue rather than a copied list of function names, so a new entry joins every applicable probe automatically.

The dimensions are independent: every A source rule is evaluated on every B path that validates or switches on a graph, for both C entry kinds. B paths that only change status cannot alter a graph, which the write-path scan proves by rejecting `:graph` in their transitive closures. Company-tenant paths return the single INV-5 code before source details are examined.

## A. Argument and graph source kinds

| Row | Case | Expected decision | Decision-record sentence | Test (`platform_call_source_class_test.exs` unless named) | Class test |
|---|---|---|---|---|---|
| A1 | `{"var": v}` names a start variable | Allow for a declared input when the activator holds the entry permission | 0094 (e): "the start variables of such a definition are trusted inputs" | A1/A2/A4: trusted variable sources are accepted | The same generated probe runs every catalogue entry |
| A2 | `{"var": v}` names an earlier platform step's output | Allow; no person or foreign node may supply it | 0094 (b): "reads only start variables or earlier platform-step outputs" | A1/A2/A4: trusted variable sources are accepted | The same generated probe runs every catalogue entry and every declared input |
| A3 | `{"var": v}` is human-task writable | Refuse `:platform_call_input_source_refused` for a write-like entry | 0094 (b): "never a human task's completer" | `platform_call_completer_refused_test.exs`; A3 probe in this file | A3 generated probe runs every write-like entry and each declared input; `write_target_sources_scan_test.exs` covers completion |
| A4 | `{"var": v}` is engine-owned/unclassified and no node writes it | Allow: it is neither person-writable nor a foreign source | 0094 (b): only start and earlier platform-step sources are trusted; the graph contains no competing writer | A1/A2/A4: trusted variable sources are accepted | The same generated probe runs every catalogue entry |
| A5 | `{"var": v}` names a reserved `_sys` key | Refuse `:platform_call_arg_sys_reference` | 0094 (b): well-formed declared sources only; engine-reserved variables are not declared start/step inputs | A5: reserved engine variables are refused | A5 generated probe runs every catalogue entry and each declared input |
| A6 | `{"var": "a.b"}` is nested/dotted | Refuse `:platform_call_arg_source_invalid` at activation; the namespace is flat and G1 must not add dotted resolution | 0094 (b): a variable name is ONE flat top-level key; dotted names are invalid and must never be resolved as paths | A6: dotted variable names are refused | A6 generated probe runs every catalogue entry and each declared input |
| A7 | `{"const": json}` is a designer-fixed literal | Allow; the value comes only from the signed graph attribute, never instance variables | 0094 (b): const is a third signed source fixed by the activator at activation time | A7: a const literal is signed and is not a completion read key | A7 generated probe accepts a const for every declared input of every catalogue entry |
| A8 | A required argument is missing | Refuse `:platform_call_arg_missing` | 0094 (b): declared inputs, "the required ones present" | A8: every required argument is enforced | A8 generated probe removes each required input of every catalogue entry in turn |
| A9 | An argument name is not declared | Refuse `:platform_call_arg_unknown` | 0094 (b): every argument has "a declared name" | A9: unknown argument names are refused | A9 generated probe adds an unknown argument to every catalogue entry |
| A10 | Source is malformed, has extra keys, or has a blank variable | Refuse `:platform_call_arg_source_invalid` | 0094 (b): "one well-formed source each" | A10: malformed argument sources are refused | A10 generated probe tries every malformed shape on every catalogue entry |
| A11 | The call map carries an unknown key | Refuse `:platform_call_unknown_key` | 0094 (b): the call shape has closed keys | A11: unknown call keys are refused | A11 generated probe runs every catalogue entry |
| A12 | The call is not a map, has a blank function, or has non-map args | Refuse `:platform_call_malformed` | 0094 (b): a malformed attribute is declared and refused, never guessed | A12: malformed calls are refused | A12 generated probe tries every malformed call shape |
| A13 | Function is absent from the compiled catalogue | Refuse `:platform_call_function_unknown` | 0094 (a): an entry exists only if it is in the build | `platform_call_activation_authority_test.exs` S1d | `catalog_test.exs` derives the exact compiled chain; activation/signature suites probe an unknown name |
| A14 | `platform_call` appears on a non-SERVICE_TASK node | Refuse `:platform_call_node_type_not_supported` | 0094 (b): the step kind is a SERVICE_TASK attribute | A14: non-service nodes are refused | A14 generated probe runs every catalogue entry on every other node type |
| A15 | The node also has `endpoint`, `service_id`, or `script_key` | Refuse `:conflicting_platform_call_routes` | 0094 (b): "The step kinds are EXCLUSIVE" | `platform_call_foreign_source_refused_test.exs` | That suite loops all three conflicting route attributes at graph validation and checks activation/dispatch |
| A16 | Inline HTTP, script, or sub-process output can overwrite a write-like input | Refuse `:platform_call_foreign_source_refused` | 0094 (b): a write-like call carries no foreign source | `platform_call_foreign_source_refused_test.exs` | That suite covers all three foreign node kinds at activation and the graph guard at dispatch |

## B. Definition write and switch-on paths

| Row | Path | Expected decision | Decision-record sentence | Test | Class test |
|---|---|---|---|---|---|
| B1 | Create | Company tenant refuses with `:platform_call_not_allowed`; platform draft may be stored | 0094 "The one code a company tenant ever sees" | `platform_call_write_path_refused_test.exs` | `platform_call_write_paths_scan_test.exs` `:graph_write` |
| B2 | Import, including variable schemas | Same tenant refusal before storage | 0094 (b) and "The one code…" | `platform_call_company_tenant_refused_test.exs` | Write-path scan covers both public import functions |
| B3 | Update PUT | Same refusal; no partial graph write | 0094 "the UPDATE path (PUT and PATCH)" | `platform_call_write_path_refused_test.exs` | Write-path scan derives `update` and requires the tenant check |
| B4 | Update PATCH | Same refusal; no partial graph write | 0094 "the UPDATE path (PUT and PATCH)" | `platform_call_write_path_refused_test.exs` | The router uses the same scanned `update` entry point |
| B5 | Activate | Require platform tenant, valid sources, and entry permission in the signed activator | 0094 (b): activation signs only after the authority check | `platform_call_activation_authority_test.exs` | Write-path scan `:switch_on`; A-row probes call the common activation validator |
| B6 | Reactivate | Repeat the full activation fence | 0094 (b): every path signing `activated_by` repeats the check | `platform_call_activator_signature_test.exs` | Write-path scan classifies `reactivate` as `:switch_on` |
| B7 | Version rollback | Repeat the full activation fence | 0094 (b): "Activation, version rollback and promotion all run the same check" | `platform_call_activation_authority_test.exs` S1e | Write-path scan classifies rollback as `:switch_on` |
| B8 | Promotion apply / active promotion | Check the target tenant and activator again | 0094 (b) and "The one code…" | `platform_call_company_tenant_refused_test.exs` | Write-path scan covers all three public promotion writers |
| B9 | Designer validation | Company tenant receives the one fixed code | 0094 "The one code a company tenant ever sees" | `platform_call_company_tenant_refused_test.exs` | The route test exercises the same public validation fence; write-path scan covers storage paths |
| B10 | Deactivate, archive, hard delete, reactivation marks/reconciliation | Status-only; cannot change a graph | 0094 (d): no new audit rows are invented for status-only paths | `platform_call_write_paths_scan_test.exs` status-only proof | The scan includes `Letflow.Definitions.Reactivation` and rejects `:graph` in every status-only transitive closure |
| B11 | System caller (module, seed, reconciliation) | No person actor; audit row has `actor_kind: "system"` | 0094 (d): a non-person caller is distinguished from a user by the row | `definition_audit_actor_test.exs` | `definition_audit_actor_paths_scan_test.exs` derives every lifecycle audit writer and router caller |

## C. Catalogue entry kinds

| Row | Entry kind | Expected decision | Decision-record sentence | Test | Class test |
|---|---|---|---|---|---|
| C1 | Write-like: any side effect not class `:read` | May not declare a `:person` input; A3/A5–A12/A16 apply | 0094 (a)/(b): source class is part of the compiled contract and write-like inputs are never person-controlled | `catalog_test.exs` compile-time refusal; all A-row write-like probes | `Entry.validate_catalogue!/1` runs on the complete compiled catalogue; generated A probes use `Entry.write_like?/1` |
| C2 | Read-only (`:read`, currently `tenant.validate`) | A `:person` input is structurally allowed; the foreign-source write rule does not apply, while argument-shape rules still do | 0094 (b) scopes the foreign-source rule explicitly to a write-like call | `catalog_test.exs` read-only acceptance; A5–A12 probes include this entry | Generated A probes enumerate all entries, including every present or future read-only entry |

## Mechanical coverage invariant

`platform_call_source_class_test.exs` obtains entries through `Catalog.list(platform_tenant?: true)` and inputs through each entry's own declarations. It does not duplicate the six-name catalogue list. Its generated probes cover A1–A12 and A14 across that complete set; A13/A15/A16 and all B/C rows have the scans or generated loops named above. A new source shape, write entry point, or catalogue entry therefore fails a test until it is classified and checked.
