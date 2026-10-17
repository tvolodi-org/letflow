defmodule Letflow.ServiceCatalog.EndpointUrlDbGuardChangesetTest do
  @moduledoc """
  GH #2638 T4 + T5: a violation of the DB CHECK reached THROUGH a changeset surfaces as a stable
  `{:error, %Ecto.Changeset{}}` (never a raised `Postgrex.Error`, so never a 500), recognised by
  `Entry.reserved_endpoint_url_error?/1`, the function the admin router uses to choose the 422
  `endpoint_url_reserved_variable` answer. The DB branch is not reachable over HTTP while the
  Elixir predicate and the pattern agree, so it is covered here with the real constraint (the
  URL is swapped in AFTER validation) and with injected changesets. Also pins "no behaviour
  change for valid entries" with an ordinary templated URL through every writer.
  Design: `lib/letflow/design/gh2638-catalog-endpoint-sys-db-guard.md` (rev 2) section 6.
  Spec: `test/specs/GH-2638.md`.

  `async: false`, `:auto` mode: `service_catalog` is a GLOBAL table; rows deleted in `on_exit/1`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Changeset, only: [put_change: 3, add_error: 4]
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version

  @good_url "https://example.test/svc"
  @templated_url "https://example.test/{{variables.order_id}}"
  @reserved_url "https://example.test/{{variables._sys.secretname}}"
  @live_check "chk_service_catalog_endpoint_url_no_reserved_ref"
  @versions_check "chk_service_catalog_versions_endpoint_url_no_reserved_ref"
  @message "must not reference the reserved engine variable namespace"

  setup do
    Sandbox.mode(Repo, :auto)
    :ok
  end

  defp unique_service_id,
    do: "gh2638-cs-svc-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        service_id: unique_service_id(),
        endpoint_url: @good_url,
        required_auth: :NONE,
        timeout_ms: 5_000,
        scope: :global
      },
      overrides
    )
  end

  defp register!(overrides \\ %{}) do
    a = attrs(overrides)
    on_exit(fn -> cleanup_entry!(a.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(a)
    entry
  end

  defp assert_db_constraint_error(%Ecto.Changeset{} = cs, constraint_name) do
    assert {@message, opts} = cs.errors[:endpoint_url]
    assert opts[:constraint] == :check
    assert opts[:constraint_name] == constraint_name
    assert Entry.reserved_endpoint_url_error?(cs)
  end

  # -- T4: real constraint, reached through a changeset ----------------------

  describe "T4 DB violation through a changeset" do
    test "insert_changeset: URL swapped in after validation -> {:error, changeset}, nothing inserted" do
      a = attrs()
      on_exit(fn -> cleanup_entry!(a.service_id) end)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      cs =
        %Entry{
          created_at: now,
          updated_at: now,
          version_id: Ecto.UUID.generate(),
          published_at: now
        }
        |> Entry.insert_changeset(a)

      assert cs.valid?
      refute Entry.reserved_endpoint_url_error?(cs)

      assert {:error, %Ecto.Changeset{} = failed} =
               cs |> put_change(:endpoint_url, @reserved_url) |> Repo.insert()

      assert_db_constraint_error(failed, @live_check)
      assert Repo.get(Entry, a.service_id) == nil
    end

    test "publish_changeset: URL swapped in after validation -> {:error, changeset}, row unchanged" do
      entry = register!()

      cs =
        Entry.publish_changeset(entry, %{
          version_id: Ecto.UUID.generate(),
          version: "2",
          status: :ACTIVE,
          published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          endpoint_url: @good_url,
          required_auth: :NONE,
          timeout_ms: 6_000
        })

      assert cs.valid?

      assert {:error, %Ecto.Changeset{} = failed} =
               cs |> put_change(:endpoint_url, @reserved_url) |> Repo.update()

      assert_db_constraint_error(failed, @live_check)
      assert Repo.get!(Entry, entry.service_id).version == "1"
      assert Repo.get!(Entry, entry.service_id).endpoint_url == @good_url
    end

    test "Version.archive_changeset: reserved URL -> {:error, changeset} naming the versions constraint" do
      sid = unique_service_id()
      on_exit(fn -> cleanup_entry!(sid) end)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      cs =
        Version.archive_changeset(%{
          version_id: Ecto.UUID.generate(),
          service_id: sid,
          version: "1",
          endpoint_url: @reserved_url,
          required_auth: :NONE,
          timeout_ms: 5_000,
          published_at: now,
          retired_at: now
        })

      assert {:error, %Ecto.Changeset{} = failed} = Repo.insert(cs)
      assert_db_constraint_error(failed, @versions_check)
      assert Repo.get(Version, cs.changes.version_id) == nil
    end
  end

  # -- T4/T5: the recogniser, pure ------------------------------------------

  describe "Entry.reserved_endpoint_url_error?/1" do
    defp blank, do: Ecto.Changeset.change(%Entry{})

    test "true for the validator form (validation: :endpoint_url_reserved_variable)" do
      cs =
        add_error(blank(), :endpoint_url, @message, validation: :endpoint_url_reserved_variable)

      assert Entry.reserved_endpoint_url_error?(cs)
    end

    test "true for the constraint form of BOTH constraint names (the inherited-URL router branch)" do
      for name <- [@live_check, @versions_check] do
        cs =
          add_error(blank(), :endpoint_url, @message, constraint: :check, constraint_name: name)

        assert Entry.reserved_endpoint_url_error?(cs), "expected true for #{name}"
      end
    end

    test "true when the reserved error sits among unrelated errors" do
      cs =
        blank()
        |> add_error(:timeout_ms, "is invalid", validation: :number)
        |> add_error(:endpoint_url, @message, constraint: :check, constraint_name: @live_check)

      assert Entry.reserved_endpoint_url_error?(cs)
    end

    test "false for a clean changeset" do
      refute Entry.reserved_endpoint_url_error?(blank())
    end

    test "false for a length error and a scheme (not-allowed) error on endpoint_url" do
      length_cs = add_error(blank(), :endpoint_url, "too long", validation: :length, kind: :max)

      scheme_cs =
        add_error(blank(), :endpoint_url, "not allowed", validation: :endpoint_url_not_allowed)

      refute Entry.reserved_endpoint_url_error?(length_cs)
      refute Entry.reserved_endpoint_url_error?(scheme_cs)
    end

    test "false for an unrelated check constraint, even on :endpoint_url" do
      other_field =
        add_error(blank(), :scope, "inconsistent",
          constraint: :check,
          constraint_name: "chk_service_catalog_scope_owner_consistency"
        )

      other_name_same_field =
        add_error(blank(), :endpoint_url, "too long",
          constraint: :check,
          constraint_name: "chk_service_catalog_endpoint_url_length"
        )

      refute Entry.reserved_endpoint_url_error?(other_field)
      refute Entry.reserved_endpoint_url_error?(other_name_same_field)
    end

    test "false when the reserved constraint name is attached to a different field or kind" do
      other_field =
        add_error(blank(), :scope, @message, constraint: :check, constraint_name: @live_check)

      other_kind =
        add_error(blank(), :endpoint_url, @message,
          constraint: :unique,
          constraint_name: @live_check
        )

      refute Entry.reserved_endpoint_url_error?(other_field)
      refute Entry.reserved_endpoint_url_error?(other_kind)
    end

    test "changeset-level inherited reserved URL carries the code; a clean supplied URL does not" do
      inherited = %Entry{service_id: "gh2638-inh", endpoint_url: @reserved_url}

      base = %{
        version_id: Ecto.UUID.generate(),
        version: "2",
        status: :ACTIVE,
        published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        required_auth: :NONE,
        timeout_ms: 6_000
      }

      assert Entry.reserved_endpoint_url_error?(Entry.publish_changeset(inherited, base))

      refute Entry.reserved_endpoint_url_error?(
               Entry.publish_changeset(inherited, Map.put(base, :endpoint_url, @good_url))
             )
    end
  end

  # -- T5: no behaviour change for valid entries -----------------------------

  describe "valid entries are unaffected" do
    test "register, publish, retire, update_scope and delete with an ordinary templated URL" do
      entry = register!(%{endpoint_url: @templated_url})
      assert entry.endpoint_url == @templated_url

      assert {:ok, published} =
               ServiceCatalog.publish(entry.service_id, "2", %{
                 endpoint_url: "https://example.test/v2/{{variables.order_id}}",
                 timeout_ms: 6_000
               })

      assert published.version == "2"

      assert Repo.aggregate(from(v in Version, where: v.service_id == ^entry.service_id), :count) ==
               1

      assert {:ok, %Entry{} = retired} = ServiceCatalog.retire(entry.service_id)
      assert retired.status == :RETIRED

      assert {:ok, %Entry{}} = ServiceCatalog.update_scope(entry.service_id, %{scope: :global})

      assert :ok = ServiceCatalog.delete(entry.service_id)
      assert Repo.get(Entry, entry.service_id) == nil
    end

    test "the changeset still refuses a reserved URL first, with the validator code (no DB round trip)" do
      sid = unique_service_id()
      on_exit(fn -> cleanup_entry!(sid) end)

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.register(attrs(%{service_id: sid, endpoint_url: @reserved_url}))

      assert {_msg, opts} = cs.errors[:endpoint_url]
      assert opts[:validation] == :endpoint_url_reserved_variable
      refute opts[:constraint] == :check
      assert Entry.reserved_endpoint_url_error?(cs)
    end
  end
end
