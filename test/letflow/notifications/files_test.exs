defmodule Letflow.Notifications.FilesTest do
  @moduledoc """
  T-2596 (pilot gap G12): the tenant-scoped NOTIFICATION FILE AREA -- the
  place the "file" channel of a notification step writes into.

  The tests below are the acceptance of the area:

    * FA1 -- the name the server generates holds no path, whatever the
      declared name was (the traversal question, asked of the name itself);
    * FA2 -- the row lives in the tenant's own schema and the tenant of the
      row is derived from the prefix (INV-1, INV-1 (c));
    * FA3 -- a file over the cap is refused, not truncated (SF-01);
    * FA4 -- the list holds the names and never the bytes;
    * FA5 -- the retention: a file past its moment is removed by the sweep;
    * FA6 -- the area enforces its OWN byte cap on the declared name and
      refuses a name that is not valid UTF-8 (SF-01: the bound comes first);
    * FA7 -- every READ path refuses a prefix that names no tenant with an
      error tuple, exactly as the write path does: none of them raises.

  `async: false`: committed tenant writes.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Notifications.File
  alias Letflow.Notifications.Files
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: PCF

  setup do
    fx = PCF.tenant!("t2596-files")
    {:ok, fx: fx}
  end

  defp write!(fx, attrs \\ %{}) do
    {:ok, row} =
      Files.write(
        fx.schema_name,
        Map.merge(
          %{
            template_key: "tenant_registered",
            content_type: Files.content_type(),
            bytes: "Tenant acme is registered\n",
            trigger_ref: Ecto.UUID.generate(),
            declared_name: "registration-notice"
          },
          attrs
        )
      )

    row
  end

  describe "the name the server generates (the traversal question)" do
    test "FA1 the stored name holds no path, whatever the declared name was" do
      for declared <- [
            "../etc/passwd",
            "/etc/passwd",
            "..\\windows",
            "a/b",
            "~/secret",
            "C:\\Windows",
            "....//....//x",
            "",
            "  ",
            String.duplicate("a", 300)
          ] do
        name = Files.stored_name(declared)

        refute name =~ "/"
        refute name =~ "\\"
        refute name =~ ".."
        refute name =~ ":"
        refute name =~ "~"
        assert String.match?(name, ~r/\A[a-z0-9_-]+-[0-9a-f]{12}\.txt\z/), name
      end
    end

    test "FA1b two files of the same declared name get two different names" do
      refute Files.stored_name("registration-notice") == Files.stored_name("registration-notice")
    end

    test "FA1c the declared name is not stored verbatim", %{fx: fx} do
      row = write!(fx, %{declared_name: "Registration Notice"})

      assert row.name =~ ~r/\Aregistration-notice-[0-9a-f]{12}\.txt\z/
      refute row.name == "Registration Notice"
    end
  end

  describe "the area of the tenant" do
    test "FA2 the row lives in the tenant's own schema and the tenant is derived from it", %{
      fx: fx
    } do
      other = PCF.tenant!("t2596-files-other")
      row = write!(fx)

      assert row.tenant_id == fx.tenant_id

      # The row is in THIS tenant's schema and in no other one.
      assert length(Repo.all(File, prefix: fx.schema_name)) == 1
      assert Repo.all(File, prefix: other.schema_name) == []
    end

    test "FA2b a prefix that names no tenant is refused: nothing is written", %{fx: fx} do
      assert {:error, :invalid_schema_name} =
               Files.write("tenant_not_a_tenant", %{
                 template_key: "tenant_registered",
                 content_type: Files.content_type(),
                 bytes: "x",
                 declared_name: "x"
               })

      # A prefix that is not a tenant schema name at all is refused with the
      # same code -- the area's contract is one code for "no tenant here".
      assert {:error, :invalid_schema_name} =
               Files.write(nil, %{
                 template_key: "tenant_registered",
                 content_type: Files.content_type(),
                 bytes: "x",
                 declared_name: "x"
               })

      # "Nothing is written" -- not into the refused prefix, and not into the
      # tenant's own schema either: the refusal happens before any write.
      assert Repo.all(File, prefix: fx.schema_name) == []
    end

    test "FA3 a file over the cap is refused, not truncated", %{fx: fx} do
      over = String.duplicate("a", Files.max_file_bytes() + 1)

      assert {:error, :file_too_large} =
               Files.write(fx.schema_name, %{
                 template_key: "tenant_registered",
                 content_type: Files.content_type(),
                 bytes: over,
                 declared_name: "big"
               })
    end

    test "FA6 a declared name over the area's own byte cap is refused (SF-01)", %{fx: fx} do
      over = String.duplicate("a", Files.max_declared_name_bytes() + 1)

      assert {:error, :file_name_invalid} =
               Files.write(fx.schema_name, %{
                 template_key: "tenant_registered",
                 content_type: Files.content_type(),
                 bytes: "x",
                 declared_name: over
               })

      assert Repo.all(File, prefix: fx.schema_name) == []
    end

    test "FA6b a declared name that is not valid UTF-8 is refused, not walked", %{fx: fx} do
      # The sanitiser walks the name's characters; an invalid sequence must not
      # reach it (the walk raises), so the area refuses the name first.
      invalid = <<0xFF, 0xFE, "notice">>

      assert {:error, :file_name_invalid} =
               Files.write(fx.schema_name, %{
                 template_key: "tenant_registered",
                 content_type: Files.content_type(),
                 bytes: "x",
                 declared_name: invalid
               })

      assert Repo.all(File, prefix: fx.schema_name) == []
    end

    test "FA4 the list holds the names and never the bytes", %{fx: fx} do
      write!(fx)

      assert {:ok, [row]} = Files.list(fx.schema_name)
      assert row.name != nil
      assert row.template_key == "tenant_registered"
      assert row.byte_size > 0
      refute Map.has_key?(row, :bytes)
    end

    test "FA4b the bytes are read back whole", %{fx: fx} do
      row = write!(fx, %{bytes: "the rendered notification\n"})

      assert {:ok, fetched} = Files.fetch(fx.schema_name, row.id)
      assert fetched.bytes == "the rendered notification\n"
      assert fetched.sha256 == row.sha256
    end

    test "FA5 a file past its retention moment is removed by the sweep", %{fx: fx} do
      row = write!(fx)

      # Move the moment of the file into the past.
      Repo.update_all(
        from(f in File, where: f.id == ^row.id),
        [set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]],
        prefix: fx.schema_name
      )

      assert {:ok, 1} = Files.delete_expired(fx.schema_name)
      assert {:ok, []} = Files.list(fx.schema_name)
    end

    test "FA5b a file inside its retention moment survives the sweep", %{fx: fx} do
      write!(fx)

      assert {:ok, 0} = Files.delete_expired(fx.schema_name)
      assert {:ok, [_row]} = Files.list(fx.schema_name)
    end

    test "FA7 the READ paths refuse a prefix that names no tenant, they do not raise", %{
      fx: fx
    } do
      write!(fx)

      # The prefix names no tenant: the area answers, it does not reach the
      # database (the schema of a prefix that names no tenant does not exist).
      assert {:error, :invalid_schema_name} = Files.list("tenant_not_a_tenant")
      assert :error = Files.fetch("tenant_not_a_tenant", Ecto.UUID.generate())
      assert {:error, :invalid_schema_name} = Files.delete_expired("tenant_not_a_tenant")

      # The tenant's own files are untouched by the refusals.
      assert {:ok, [_row]} = Files.list(fx.schema_name)
    end

    test "FA7b the READ paths of a prefix that names no tenant do not touch the tenant's files",
         %{fx: fx} do
      row = write!(fx)

      assert :error = Files.fetch("tenant_not_a_tenant", row.id)
      assert {:error, :invalid_schema_name} = Files.delete_expired("tenant_not_a_tenant")

      assert {:ok, [_still]} = Files.list(fx.schema_name)
      assert {:ok, ^row} = Files.fetch(fx.schema_name, row.id)
    end
  end
end
