defmodule Letflow.Modules.FixtureLedgerPost do
  @moduledoc """
  Test-only entry module (REQ-684 / GH #3698, decision 0073 slice L3a): declares valid ledger
  registrations (REQ-830: `gamma` names a scope slot), `alpha` (fixed ledger id `fixture_ledger_post`) and `beta`
  (`fixture_ledger_post:beta`), so the later slices can post two ledgers in one transaction (`beta` also declares a REQ-764 posting guard). It has
  its own four permission atoms (no role is granted any of them), one error alias on `alpha`, a
  policy in `ledger_policy/`, two posting handlers and a plain `create/3` handler. One pack (REQ-685: only the `fxlp_note` entity type), no
  `on_install`, no router. Registered only in `config/test.exs`, last in the list.
  """

  @behaviour Letflow.Modules.Module

  import Letflow.Modules.Module, only: [defmanifest: 1]

  @impl true
  defmanifest(
    id: "fixture_ledger_post",
    version: "0.1.0",
    depends_on: [],
    pack: "module_fixtures/ledger_post.json",
    permissions: [:FxlpPost, :FxlpReverse, :FxlpRead, :FxlpReconcile],
    role_grants: %{},
    required_roles: [],
    settings_schema: nil,
    route_policies: [],
    manages_entity_types: ["fxlp_note"],
    write_handlers: [
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_alpha",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_alpha},
        targets: ["fxlp_note"],
        args: %{
          "note" => %{required: true},
          "posting" => %{required: false},
          "twice" => %{required: false},
          "skip_note" => %{required: false},
          "before" => %{required: false}
        },
        posts_ledger: "alpha",
        # D-204 (the module-process conversion, section 1.2): the four
        # MODULE-FAMILY fields. `post_alpha` is the ONE handler of a fake
        # module that opts into the module family, so the derivation has a
        # worked example to test against (a handler without a permission stays
        # on the old owner-stamp path and is no catalogue entry).
        permission: :FxlpPost,
        outputs: [%{name: "note_id", type: :uuid}, %{name: "ledger_entry_id", type: :uuid}],
        idempotency_inputs: ["note"],
        side_effect_classes: [:write_module_record, :ledger_post]
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_beta",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_beta},
        targets: ["fxlp_note"],
        args: %{
          "note" => %{required: true},
          "posting" => %{required: false},
          "twice" => %{required: false},
          "skip_note" => %{required: false},
          "before" => %{required: false}
        },
        posts_ledger: "beta"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_gamma",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_gamma},
        targets: ["fxlp_note"],
        args: %{
          "note" => %{required: true},
          "posting" => %{required: false},
          "twice" => %{required: false},
          "skip_note" => %{required: false},
          "before" => %{required: false}
        },
        posts_ledger: "gamma"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "plain",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :plain},
        targets: ["fxlp_note"],
        args: %{"note" => %{required: true}}
      },
      # REQ-829 (OQ-R4 read facade): `make_note` writes a note with an `active` flag, `read_probe`
      # reads one record by type and id and records the answers in a note, `read_maybe` reads once
      # (or not) and writes nothing, `post_reading` posts only in a dry build.
      %Letflow.Modules.WriteHandlerSpec{
        name: "make_note",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :make_note},
        targets: ["fxlp_note"],
        args: %{"note" => %{required: true}, "active" => %{required: true}}
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "read_probe",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :read_probe},
        targets: ["fxlp_note"],
        args: %{"type" => %{required: true}, "id" => %{required: true}},
        reads: ["fxlp_note"]
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "read_maybe",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :read_maybe},
        targets: ["fxlp_note"],
        args: %{"id" => %{required: true}, "do_read" => %{required: true}},
        reads: ["fxlp_note"]
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_reading",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_reading},
        targets: ["fxlp_note"],
        args: %{"posting" => %{required: true}},
        posts_ledger: "alpha",
        reads: ["fxlp_note"]
      },
      # REQ-902 (document read facade): `read_doc` reads one document version and records the answer in a
      # note; `read_doc_off` is the same function with `reads_documents` false; `read_doc_maybe` reads once
      # (or not) and writes nothing; `post_reading_doc` posts only in a dry build.
      %Letflow.Modules.WriteHandlerSpec{
        name: "read_doc",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :read_doc},
        targets: ["fxlp_note"],
        args: %{"document_id" => %{required: true}, "version_no" => %{required: true}},
        reads_documents: true
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "read_doc_off",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :read_doc},
        targets: ["fxlp_note"],
        args: %{"document_id" => %{required: true}, "version_no" => %{required: true}}
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "read_doc_maybe",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :read_doc_maybe},
        targets: ["fxlp_note"],
        args: %{
          "document_id" => %{required: true},
          "version_no" => %{required: true},
          "do_read" => %{required: true}
        },
        reads_documents: true
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "post_reading_doc",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :post_reading_doc},
        targets: ["fxlp_note"],
        args: %{"posting" => %{required: true}},
        posts_ledger: "alpha",
        reads_documents: true
      },
      # REQ-901: handlers that refuse with a typed code (kept last: tests take the first handler).
      %Letflow.Modules.WriteHandlerSpec{
        name: "refuse_alpha",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :refuse},
        targets: ["fxlp_note"],
        args: %{"note" => %{required: true}, "code" => %{required: true}},
        posts_ledger: "alpha"
      },
      %Letflow.Modules.WriteHandlerSpec{
        name: "refuse_plain",
        function: {Letflow.Modules.FixtureLedgerPost.Handlers, :refuse},
        targets: ["fxlp_note"],
        args: %{"note" => %{required: true}, "code" => %{required: true}}
      }
    ],
    ledger: %{
      "alpha" => %{
        ledger_ids: {:fixed, ["fixture_ledger_post"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false}
        },
        key_bounds: [%{when_slot_nonempty: "k2", max_on_hand: "1"}],
        permissions: %{
          post: :FxlpPost,
          reverse: :FxlpReverse,
          read: :FxlpRead,
          reconcile: :FxlpReconcile
        },
        scope_slot: nil,
        max_event_lateness_hours: 96,
        error_aliases: %{"insufficient_balance" => "fxlp_short"},
        policy: {Letflow.Modules.FixtureLedgerPost.LedgerPolicy, :declare}
      },
      "beta" => %{
        ledger_ids: {:fixed, ["fixture_ledger_post:beta"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "issue" => %{sign_rule: :negative, reason_required: false}
        },
        key_bounds: [%{when_slot_nonempty: "k2", max_on_hand: "1"}],
        permissions: %{
          post: :FxlpPost,
          reverse: :FxlpReverse,
          read: :FxlpRead,
          reconcile: :FxlpReconcile
        },
        scope_slot: nil,
        max_event_lateness_hours: 96,
        error_aliases: %{"posting_held" => "fxlp_held"},
        policy: {Letflow.Modules.FixtureLedgerPost.LedgerPolicy, :declare},
        posting_guard: {Letflow.Modules.FixtureLedgerPost.PostingGuard, :check}
      },
      # REQ-830 (slice L6 part 1): the one registration that names a scope slot (k2, an org unit id).
      "gamma" => %{
        ledger_ids: {:fixed, ["fixture_ledger_post:gamma"]},
        slots: [
          %{name: "k1", format: :token, required: true},
          %{name: "k2", format: :uuid, required: false}
        ],
        causes: %{
          "receipt" => %{sign_rule: :positive, reason_required: false},
          "transfer" => %{sign_rule: :any, reason_required: false}
        },
        key_bounds: [],
        permissions: %{
          post: :FxlpPost,
          reverse: :FxlpReverse,
          read: :FxlpRead,
          reconcile: :FxlpReconcile
        },
        scope_slot: "k2",
        max_event_lateness_hours: 96,
        error_aliases: %{},
        policy: {Letflow.Modules.FixtureLedgerPost.LedgerPolicy, :declare}
      }
    }
  )
end
