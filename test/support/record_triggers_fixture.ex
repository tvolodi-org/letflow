defmodule Letflow.RecordTriggersFixture do
  @moduledoc """
  REQ-570 (GH #3248) test support: script rows of any hook kind and status, hashed over their own
  content (the legal INSERT shape), with an optional manifest.
  """

  alias Letflow.Repo
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.ScriptTaskFixture, as: F

  @doc "Every `record_trigger_outbox` row of `schema`, oldest first (REQ-606)."
  @spec outbox_rows(String.t()) :: [Letflow.RecordTriggers.OutboxRow.t()]
  def outbox_rows(schema) do
    import Ecto.Query

    Repo.all(
      from(r in Letflow.RecordTriggers.OutboxRow, order_by: [asc: r.source_seq, asc: r.id]),
      prefix: schema
    )
  end

  @doc "Binds a fresh published `entity_event` script to (`type`, `event`); returns the binding."
  @spec bind!(String.t(), String.t(), String.t()) :: Letflow.RecordTriggers.Binding.t()
  def bind!(schema, type, event) do
    rule = script!(schema, "entity_event", :published)

    pin = %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

    actor = %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "req606-trace"}
    {:ok, binding} = Letflow.RecordTriggers.bind(schema, type, event, pin, actor)
    binding
  end

  @doc "A script row of `hook_kind` and `status` in `schema`; `manifest` defaults to a closed one."
  @spec script!(String.t(), String.t(), atom(), map() | nil) :: ScriptRule.t()
  def script!(schema, hook_kind, status, manifest \\ nil) do
    key = "rt#{System.unique_integer([:positive])}"
    test_cases = [%{"name" => "c1", "input" => %{}, "expect" => %{"fail" => "x"}}]
    manifest = manifest || F.closed_manifest()
    source = F.doubling_source()

    rule =
      Repo.insert!(
        %ScriptRule{
          key: key,
          version: 1,
          hook_kind: hook_kind,
          status: :draft,
          source: source,
          manifest: manifest,
          test_cases: test_cases,
          sha256: "pending",
          contributors: [Ecto.UUID.generate()]
        },
        prefix: schema
      )

    sha = Hash.compute(key, 1, hook_kind, manifest, test_cases, source)
    rule = rule |> Ecto.Changeset.change(sha256: sha) |> Repo.update!(prefix: schema)

    changes =
      case status do
        :draft ->
          []

        :discarded ->
          [status: :discarded, discarded_at: DateTime.utc_now()]

        _ ->
          publisher = Ecto.UUID.generate()

          [
            status: :published,
            publisher_id: publisher,
            published_at: DateTime.utc_now(),
            sod_excluded: rule.contributors ++ [publisher]
          ]
      end

    rule = rule |> Ecto.Changeset.change(changes) |> Repo.update!(prefix: schema)

    case status do
      :retired -> F.retire_raw!(schema, rule)
      :revoked -> F.revoke_raw!(schema, rule)
      _ -> rule
    end
  end
end
