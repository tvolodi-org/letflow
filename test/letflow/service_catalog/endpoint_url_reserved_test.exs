defmodule Letflow.ServiceCatalog.EndpointUrlReservedTest do
  @moduledoc """
  GH #2623: a service-catalog `endpoint_url` must not reference the reserved engine variable
  namespace (`{{variables._sys}}`, `{{variables._sys.<anything>}}`). Design:
  `lib/letflow/design/gh2623-catalog-endpoint-url-sys-refusal.md`.

  `async: false`: `service_catalog` is a GLOBAL table; every row is cleaned in `on_exit`.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions.ReservedReferences
  alias Letflow.Engine.ServiceTask
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version

  @good_url "https://example.test/svc"
  @code :endpoint_url_reserved_variable

  @refused [
    "https://example.test/{{variables._sys}}",
    "https://example.test/{{variables._sys.r}}",
    "https://example.test/{{variables._sys.r.seq}}",
    "https://example.test/{{variables._sys.}}",
    "https://example.test/{{ variables._sys }}",
    "https://example.test/{{\tvariables._sys.x\n}}",
    "https://{{variables._sys}}.example.test/x"
  ]

  @accepted [
    "https://example.test/{{variables._system}}",
    "https://example.test/{{variables._SYS}}",
    "https://example.test/{{variables.a._sys}}",
    "https://example.test/{{variables.x_sys}}",
    "https://example.test/_sys/{{variables.a}}",
    "https://example.test/{{Variables._sys}}"
  ]

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  defp unique_service_id,
    do: "gh2623-svc-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp attrs(overrides) do
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

  defp reserved_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:endpoint_url, {_msg, opts}} -> opts[:validation] == @code
      _ -> false
    end)
  end

  defp version_count(service_id),
    do: Repo.aggregate(from(v in Version, where: v.service_id == ^service_id), :count)

  describe "register/1" do
    test "refuses every reserved reference and inserts nothing" do
      for url <- @refused do
        a = attrs(%{endpoint_url: url})
        on_exit(fn -> cleanup_entry!(a.service_id) end)

        assert {:error, %Ecto.Changeset{} = cs} = ServiceCatalog.register(a)
        assert reserved_error?(cs), "expected reserved code for #{inspect(url)}"
        assert Repo.get(Entry, a.service_id) == nil
      end
    end

    test "accepts near-misses such as _system" do
      for url <- @accepted do
        assert %Entry{endpoint_url: ^url} = register!(%{endpoint_url: url})
      end
    end

    test "a plain bad scheme keeps the existing not-allowed code" do
      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.register(attrs(%{endpoint_url: "http://example.test/x"}))

      refute reserved_error?(cs)
      assert Keyword.has_key?(cs.errors, :endpoint_url)
    end
  end

  describe "publish/3" do
    test "refuses a supplied reserved URL and rolls back (no version row, live row unchanged)" do
      entry = register!()
      before_count = version_count(entry.service_id)

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.publish(entry.service_id, "2", %{
                 endpoint_url: "https://example.test/{{variables._sys.r}}"
               })

      assert reserved_error?(cs)
      assert version_count(entry.service_id) == before_count

      live = Repo.get!(Entry, entry.service_id)
      assert live.version == "1"
      assert live.endpoint_url == @good_url
    end

    test "accepts an _system near-miss" do
      entry = register!()

      assert {:ok, _} =
               ServiceCatalog.publish(entry.service_id, "2", %{
                 endpoint_url: "https://example.test/{{variables._system}}"
               })
    end

    # GH #2638: the DB CHECK guarantees a stored row is clean, so an inherited reserved URL can
    # no longer be created in a real database (asserted by the DB guard parity test). The
    # changeset-level behaviour is kept: publishing over a (hypothetical) stored reserved URL
    # without supplying a URL is refused, and a clean supplied URL repairs it.
    test "refuses an INHERITED reserved URL at changeset level; a clean supplied URL repairs it" do
      inherited = %Entry{
        service_id: "gh2638-inherited",
        endpoint_url: "https://example.test/{{variables._sys.r}}"
      }

      base = %{
        version_id: Ecto.UUID.generate(),
        version: "2",
        status: :ACTIVE,
        published_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        required_auth: :NONE,
        timeout_ms: 6_000
      }

      cs = Entry.publish_changeset(inherited, base)
      refute cs.valid?
      assert Entry.reserved_endpoint_url_error?(cs)

      repaired = Entry.publish_changeset(inherited, Map.put(base, :endpoint_url, @good_url))
      assert repaired.valid?
      refute Entry.reserved_endpoint_url_error?(repaired)
    end
  end

  describe "order of checks (D-9)" do
    test "a URL over 2048 bytes holding a reserved reference gets the length error" do
      url = "https://example.test/{{variables._sys}}/" <> String.duplicate("a", 2100)

      assert {:error, %Ecto.Changeset{} = cs} =
               ServiceCatalog.register(attrs(%{endpoint_url: url}))

      refute reserved_error?(cs)
      assert {_msg, opts} = cs.errors[:endpoint_url]
      assert opts[:validation] == :length
    end
  end

  describe "publish/3 bare form and near-misses" do
    test "refuses the bare and whitespace forms" do
      entry = register!()

      for {url, v} <- [
            {"https://example.test/{{variables._sys}}", "2"},
            {"https://example.test/{{  variables._sys  }}", "3"}
          ] do
        assert {:error, %Ecto.Changeset{} = cs} =
                 ServiceCatalog.publish(entry.service_id, v, %{endpoint_url: url})

        assert reserved_error?(cs)
      end

      assert Repo.get!(Entry, entry.service_id).version == "1"
    end

    test "accepts _SYS and a._sys" do
      entry = register!()

      for {url, v} <- [
            {"https://example.test/{{variables._SYS}}", "2"},
            {"https://example.test/{{variables.a._sys}}", "3"}
          ] do
        assert {:ok, _} = ServiceCatalog.publish(entry.service_id, v, %{endpoint_url: url})
      end
    end
  end

  describe "pure helpers" do
    test "Entry.check_endpoint_url_references/1 truth table" do
      for url <- @refused,
          do: assert(Entry.check_endpoint_url_references(url) == {:error, @code})

      for url <- @accepted, do: assert(Entry.check_endpoint_url_references(url) == :ok)
    end

    test "ReservedReferences.reserved_template_names/1: order, duplicates, nil, non-binary" do
      assert ReservedReferences.reserved_template_names(
               "{{variables._sys.b}}/{{variables.ok}}/{{variables._sys}}/{{variables._sys.b}}"
             ) == ["_sys.b", "_sys", "_sys.b"]

      assert ReservedReferences.reserved_template_names(nil) == []
      assert ReservedReferences.reserved_template_names(42) == []
    end
  end

  describe "derived pattern (single source of truth, invariant I-13)" do
    test "matches the dotted reserved forms and differs from the strict source" do
      derived = ServiceTask.template_reference_placeholder()

      assert Regex.match?(derived, "{{variables._sys}}")
      assert Regex.match?(derived, "{{variables._sys.x}}")
      assert Regex.match?(derived, "{{ variables._sys.a.b }}")

      assert ServiceTask.template_reference_keys("{{variables._sys}}") == ["_sys"]
      assert ServiceTask.template_reference_keys("{{variables._sys.x}}") == ["_sys.x"]
      assert ServiceTask.template_reference_keys("{{ variables._sys.a.b }}") == ["_sys.a.b"]
      assert ServiceTask.template_reference_keys(nil) == []

      # A silent no-op derivation would make these equal.
      refute Regex.source(derived) == Regex.source(ServiceTask.template_placeholder())

      # The strict grammar stays dot-free and the derived one only differs in the KEY class.
      assert ServiceTask.template_variable_keys("{{variables.a.b}}") == []
      assert ServiceTask.template_reference_keys("{{variables.a.b}}") == ["a.b"]

      assert String.replace(Regex.source(derived), "[a-zA-Z0-9_.]+", "[a-zA-Z0-9_]+") ==
               Regex.source(ServiceTask.template_placeholder())

      # A future flag on the strict pattern is inherited.
      assert Regex.opts(derived) == Regex.opts(ServiceTask.template_placeholder())
    end

    test "strict KEYs are a subsequence of derived KEYs over random templates" do
      key = StreamData.string([?a..?z, ?A..?Z, ?0..?9, ?_, ?.], min_length: 1, max_length: 8)

      check all(
              keys <- StreamData.list_of(key, max_length: 5),
              pad <- StreamData.string([?a..?z, ?/], max_length: 6)
            ) do
        template = Enum.map_join(keys, pad, &"{{ variables.#{&1} }}")
        strict = ServiceTask.template_variable_keys(template)
        derived = ServiceTask.template_reference_keys(template)

        assert Enum.filter(derived, &(&1 in strict)) == strict
      end
    end
  end

  describe "no second regex in the catalog" do
    test "lib/letflow/service_catalog has no regex literal and no _sys literal" do
      files =
        ["lib/letflow/service_catalog.ex" | Path.wildcard("lib/letflow/service_catalog/**/*.ex")]

      assert length(files) > 1

      for file <- files do
        assert forbidden_tokens(File.read!(file)) == [], "#{file} holds a forbidden token"
      end
    end

    test "the scan predicate flags each forbidden token (positive control)" do
      assert "~r" in forbidden_tokens("x = ~r/a/")
      assert "Regex." in forbidden_tokens("Regex.match?(a, b)")
      assert ~s("_sys) in forbidden_tokens(~s(k = "_sys.x"))
      assert forbidden_tokens("plain text") == []
    end

    defp forbidden_tokens(src),
      do: Enum.filter(["~r", "Regex.", ~s("_sys)], &String.contains?(src, &1))
  end
end
