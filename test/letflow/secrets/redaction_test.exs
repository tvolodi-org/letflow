defmodule Letflow.Secrets.RedactionTest do
  @moduledoc """
  Tests for REQ-190 -- `Letflow.Secrets.Redaction` (`redact_map/1`,
  `render_reference/1`), and a moduledoc-honesty check. See `test/specs/REQ-190.md`
  for the full acceptance-criterion -> test-case mapping. Design authority:
  `lib/letflow/design/req190-secrets-core.md` §6.1.

  Pure functions, no I/O, no DB -- plain `ExUnit.Case, async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Secrets.Redaction

  # ---------------------------------------------------------------------------------
  # AC7 -- redaction of the exact key list
  # ---------------------------------------------------------------------------------

  describe "AC7: redact_map/1 redacts the exact key list, keeps key names, leaves unlisted keys alone" do
    test "redact_map exact keys" do
      input = %{
        "secret" => "s3cr3t-value",
        "password" => "p@ssword-value",
        "token" => "tok-value",
        "client_secret" => "cs-value",
        "my_custom_secret" => "suffix-matched-value",
        "harmless" => "plain-value"
      }

      redacted = Redaction.redact_map(input)

      assert redacted["secret"] == "[REDACTED]"
      assert redacted["password"] == "[REDACTED]"
      assert redacted["token"] == "[REDACTED]"
      assert redacted["client_secret"] == "[REDACTED]"
      assert redacted["my_custom_secret"] == "[REDACTED]"

      # Negative case: an unlisted key must NOT be redacted -- proves this isn't a
      # bug that redacts every value indiscriminately.
      assert redacted["harmless"] == "plain-value"

      # Every key name is kept, unmodified, regardless of whether its value was
      # redacted.
      assert Map.keys(redacted) |> Enum.sort() == Map.keys(input) |> Enum.sort()
    end

    test "keys are matched case-insensitively, and via atom keys too" do
      input = %{"SECRET" => "v1", :password => "v2", "Api_Token" => "v3"}

      redacted = Redaction.redact_map(input)

      assert redacted["SECRET"] == "[REDACTED]"
      assert redacted[:password] == "[REDACTED]"
      assert redacted["Api_Token"] == "[REDACTED]"
    end

    test "redacts secret_key_base (ISS-0770 -- Plug.Conn-shaped secret field)" do
      # Plug.Conn.secret_key_base is a genuine secret-shaped field; assert it is
      # caught by the exact-key list under both atom and string key forms, using
      # a plain conn-shaped map rather than a real %Plug.Conn{} struct so this
      # test stays independent of the unrelated struct-support fix in-flight for
      # ISS-0769 (PR #1668).
      input_atom_key = %{secret_key_base: "super-secret-64-byte-value", host: "example.com"}
      input_string_key = %{"secret_key_base" => "super-secret-64-byte-value"}

      assert Redaction.redact_map(input_atom_key)[:secret_key_base] == "[REDACTED]"
      assert Redaction.redact_map(input_atom_key)[:host] == "example.com"
      assert Redaction.redact_map(input_string_key)["secret_key_base"] == "[REDACTED]"
    end

    test "recurses into nested maps and lists of maps" do
      input = %{
        "data" => %{"nested_secret" => "inner", "safe" => "kept"},
        "items" => [%{"token" => "t1"}, %{"safe" => "kept2"}]
      }

      redacted = Redaction.redact_map(input)

      assert redacted["data"]["nested_secret"] == "[REDACTED]"
      assert redacted["data"]["safe"] == "kept"
      assert [%{"token" => "[REDACTED]"}, %{"safe" => "kept2"}] = redacted["items"]
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0769 -- redaction of sensitive-keyed 2-tuples in lists (Plug.Conn.headers())
  # ---------------------------------------------------------------------------------

  describe "ISS-0769: redact_map/1 redacts sensitive-keyed 2-tuples inside lists" do
    test "header-tuple redaction is case-insensitive; key name is kept" do
      input = %{
        req_headers: [{"authorization", "Bearer tok-123"}, {"Content-Type", "application/json"}]
      }

      redacted = Redaction.redact_map(input)

      assert {"authorization", "[REDACTED]"} in redacted.req_headers
      assert {"Content-Type", "application/json"} in redacted.req_headers
    end

    test "nested inside a struct, e.g. the actual %Plug.Conn{} shape" do
      input = %{conn: %Plug.Conn{req_headers: [{"authorization", "Bearer secret-xyz"}]}}

      redacted = Redaction.redact_map(input)

      refute inspect(redacted) =~ "secret-xyz"
      assert inspect(redacted) =~ "[REDACTED]"
    end

    test "non-sensitive 2-tuples pass through unchanged" do
      item = {"content-type", "application/json"}
      input = %{headers: [item]}

      redacted = Redaction.redact_map(input)

      assert redacted.headers == [item]
    end

    test "set-cookie / cookie header tuples are redacted wholesale" do
      input = %{resp_headers: [{"set-cookie", "session=abc"}, {"cookie", "other=xyz"}]}

      redacted = Redaction.redact_map(input)

      assert {"set-cookie", "[REDACTED]"} in redacted.resp_headers
      assert {"cookie", "[REDACTED]"} in redacted.resp_headers
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- reference-redaction masking
  # ---------------------------------------------------------------------------------

  describe "AC8: render_reference/1 masks the key_id segment" do
    test "render_reference" do
      pinned = "sec://tenant/acme/webhook/sub-1#7"
      unpinned = "sec://tenant/acme/webhook/sub-1"

      assert Redaction.render_reference(pinned) == "sec://tenant/acme/webhook/sub-1#***"
      assert Redaction.render_reference(unpinned) == unpinned
    end
  end

  # ---------------------------------------------------------------------------------
  # AC10 -- moduledoc honest-limitation statement
  # ---------------------------------------------------------------------------------

  describe "AC10: moduledoc states the honest field-name-only limitation" do
    test "moduledoc honesty" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Secrets.Redaction)

      assert moduledoc =~ ~r/field NAME/i

      assert moduledoc =~ "not caught" or moduledoc =~ "NOT caught"

      refute moduledoc =~ ~r/guarantees? (complete|full|all)/i
    end
  end
end
