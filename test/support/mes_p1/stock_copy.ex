defmodule Letflow.Proof.MesP1.StockCopy do
  @moduledoc """
  MES PROOF P1 (T-1829), REMOVABLE with `git rm -r test/support/mes_p1 test/letflow/proof/mes_p1`.

  The manifest of the COPY of module `stock`: the real manifest with version "0.18.0", two more causes (`consume`,
  `produce`), the copied policy and the composed hold guard. It is NOT a registered module: it is in no catalog, no tenant
  installs it, no real code calls it. It only gives the tests a manifest map to hash and a registration to post with.
  The entry-module name is the prefix of the policy and guard modules (rule 18 of `LedgerRegistration`).

  `post/3` MIRRORS `Letflow.Ledger.HandlerPost` (shared hold, guard with the neutral summary, then `Ledger.post/1`); it does
  not run the engine or task path, which would need the copy in the compile-time catalog. The real seam is covered by
  `test/letflow/ledger/posting_guard_test.exs`.
  """

  alias Letflow.Ledger
  alias Letflow.LedgerFixture
  alias Letflow.Modules.LedgerRegistration
  alias Letflow.Modules.Stock
  alias Letflow.Proof.MesP1.StockCopy.HoldGuard
  alias Letflow.Proof.MesP1.StockCopy.Policy
  alias Letflow.Repo

  @version "0.18.0"
  @new_causes %{
    "consume" => %{sign_rule: :negative, reason_required: false},
    "produce" => %{sign_rule: :positive, reason_required: false}
  }

  def version, do: @version

  @doc "The copy manifest: all of the proof changes, or only the part `part` (to measure what moves the hash)."
  @spec manifest_variant(:all | :version | :policy | :causes | :guard) :: map()
  def manifest_variant(part) do
    real = Stock.manifest()
    reg = real.ledger["stock"]

    {version, reg} =
      case part do
        :all ->
          {@version,
           %{
             reg
             | causes: Map.merge(reg.causes, @new_causes),
               policy: {Policy, :declare},
               posting_guard: {HoldGuard, :check}
           }}

        :version ->
          {@version, reg}

        :policy ->
          {real.version, %{reg | policy: {Policy, :declare}}}

        :causes ->
          {real.version, %{reg | causes: Map.merge(reg.causes, @new_causes)}}

        :guard ->
          {real.version, %{reg | posting_guard: {HoldGuard, :check}}}
      end

    %{real | version: version, ledger: %{"stock" => reg}}
  end

  def manifest, do: manifest_variant(:all)

  @doc "The plain registration of the copy (as `Letflow.Ledger.post/1` reads it)."
  def registration, do: LedgerRegistration.to_plain(manifest().ledger["stock"])

  @doc "The plain registration of the REAL stock module (the old era)."
  def real_registration, do: LedgerRegistration.to_plain(Stock.manifest().ledger["stock"])

  def slot_names, do: Enum.map(registration().slots, & &1.name)

  @doc "An `Authorized` value for reconcile of the `stock` ledger (the slot names of the copy)."
  def authorized(schema, purpose \\ :reconcile) do
    %Ledger.Authorized{
      prefix: schema,
      tenant_id: nil,
      ledger_id: "stock",
      registration_name: "stock",
      purpose: purpose,
      slot_names: slot_names()
    }
  end

  @doc """
  Declares `command` with the policy of `era` (`:copy`, default, or `:real`), then posts it in one transaction:
  shared hold, the guard of that era's registration (the copy composes freeze and lot hold; the real one is the
  freeze guard), then `Ledger.post/1` and the `ledger.posted` audit entry. Returns `{:ok, posted}`, `{:error, reason}`
  (a policy refusal, a core refusal) or `{:error, {:held, label}}`. A guard raise propagates.
  """
  @spec post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(schema, command, opts \\ []) do
    era = Keyword.get(opts, :era, :copy)
    {registration, policy} = era(era)

    with {:ok, posting} <- policy.declare(command, registration) do
      Repo.transaction(fn ->
        Ledger.hold_shared!(schema, "stock")

        case guard(era, schema, posting, registration) do
          :ok -> :ok
          {:held, label} -> Repo.rollback({:held, label})
        end

        cap =
          LedgerFixture.capability(schema, posting.cause, posting.legs,
            registration: registration,
            posting: Map.drop(posting, [:cause, :legs]),
            command: command
          )

        case Ledger.post(cap) do
          {:ok, posted} ->
            audit!(cap, posted)
            posted

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  defp era(:copy), do: {registration(), Policy}
  defp era(:real), do: {real_registration(), Letflow.Modules.Stock.LedgerPolicy}

  defp guard(era, schema, posting, registration) do
    summary = %{
      ledger_id: "stock",
      cause: posting.cause,
      document_type: Map.get(posting, :document_type),
      document_id: Map.get(posting, :document_id),
      keys: keys(posting, registration)
    }

    case era do
      :copy -> HoldGuard.check(schema, summary)
      :real -> Letflow.Modules.Stock.FreezeGuard.check(schema, summary)
    end
  end

  # As `HandlerPost.guard_summary/1`: the slot maps of the legs, unique and sorted. A reversal has no legs here.
  defp keys(posting, registration) do
    names = Enum.map(registration.slots, & &1.name)

    posting.legs
    |> Enum.map(&Enum.take(&1.k, length(names)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn k -> names |> Enum.zip(k) |> Map.new() end)
  end

  defp audit!(cap, %{duplicate: false} = posted) do
    %{rows: [[cause, leg_count]]} =
      Repo.query!(
        ~s|SELECT cause, leg_count FROM "#{cap.prefix}".ledger_entry WHERE id = $1|,
        [Ecto.UUID.dump!(posted.entry_id)]
      )

    summary = %{
      entry_id: posted.entry_id,
      ledger_id: posted.ledger_id,
      posting_seq: posted.posting_seq,
      cause: cause,
      leg_count: leg_count,
      chain_hash: posted.chain_hash
    }

    {:ok, _} =
      Letflow.Audit.insert_entry(
        Repo,
        Letflow.Audit.LedgerPosted.attrs(summary, cap.actor_id),
        cap.prefix
      )
  end

  defp audit!(_cap, _duplicate), do: :ok
end
