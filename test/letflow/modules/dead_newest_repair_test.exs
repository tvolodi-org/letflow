Code.require_file("assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Modules.DeadNewestRepairTest do
  @moduledoc """
  T-3014: the ensure-seeds step brings a module process whose CURRENT version is retired (and with
  nothing ACTIVE) back to ACTIVE through the product's own path. The fixture is the shape of the
  QA tenant `qoimeks-qa2`: stock_receipt of the current module version ARCHIVED, older module
  versions DEPRECATED, no ACTIVE row.

  Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Fx
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Installs

  @name "stock_receipt"

  defp seed(schema) do
    Installs.ensure_module_seeds("stock", Ecto.UUID.generate(), "T-3014 test", prefix: schema)
  end

  defp rows(schema) do
    Repo.all(
      from(p in ProcessDefinition, where: p.name == @name, order_by: p.created_at),
      prefix: schema
    )
  end

  defp status_of(rows, status), do: Enum.filter(rows, &(&1.status == status))

  test "DN-1: archived current version, no ACTIVE row: one seed run re-activates it, a second changes nothing" do
    fx = Fx.installed_tenant!("t3014-dead")
    schema = fx.schema_name
    assert {:ok, _} = seed(schema)

    [current] = status_of(rows(schema), :active)

    # the QA state: the module's own ACTIVE row archived (what DELETE did before T-3014)
    Repo.update_all(
      from(p in ProcessDefinition, where: p.id == ^current.id),
      [set: [status: :archived, archived_at: DateTime.utc_now()]],
      prefix: schema
    )

    assert status_of(rows(schema), :active) == []

    assert {:ok, report} = seed(schema)

    assert [created] =
             report["process_drafts"] |> Enum.filter(&String.starts_with?(&1, @name <> "@"))

    assert created =~ "-repair-"
    assert created in report["process_activated"]

    after_rows = rows(schema)
    assert [active] = status_of(after_rows, :active)
    assert active.owner_module == "stock"
    assert active.owner_body_hash == current.owner_body_hash
    # the archived row is kept as history, nothing is deleted
    assert Enum.any?(after_rows, &(&1.id == current.id and &1.status == :archived))

    assert {:ok, again} = seed(schema)
    assert Enum.filter(again["process_drafts"], &String.starts_with?(&1, @name <> "@")) == []
    assert Enum.filter(again["process_activated"], &String.starts_with?(&1, @name <> "@")) == []
    assert length(rows(schema)) == length(after_rows)
  end

  test "DN-2: a healthy tenant (an ACTIVE row) is not touched" do
    fx = Fx.installed_tenant!("t3014-ok")
    schema = fx.schema_name
    assert {:ok, _} = seed(schema)
    before = rows(schema)

    assert {:ok, report} = seed(schema)
    assert report["process_drafts"] == [] and report["process_activated"] == []
    assert rows(schema) == before
  end

  test "DN-3: a DEPRECATED current version with nothing ACTIVE is repaired once" do
    fx = Fx.installed_tenant!("t3014-draft")
    schema = fx.schema_name
    assert {:ok, _} = seed(schema)
    [current] = status_of(rows(schema), :active)

    Repo.update_all(
      from(p in ProcessDefinition, where: p.id == ^current.id),
      [set: [status: :deprecated]],
      prefix: schema
    )

    assert {:ok, _} = seed(schema)
    assert [_] = status_of(rows(schema), :active)
    assert length(rows(schema)) == 2
  end
end
