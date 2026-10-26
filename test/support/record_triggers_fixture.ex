defmodule Letflow.RecordTriggersFixture do
  @moduledoc """
  REQ-570 (GH #3248) test support: script rows of any hook kind and status, hashed over their own
  content (the legal INSERT shape), with an optional manifest.
  """

  alias Letflow.Repo
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.ScriptTaskFixture, as: F

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
