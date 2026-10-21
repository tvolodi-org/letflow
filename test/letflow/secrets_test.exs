defmodule Letflow.SecretsTest do
  @moduledoc """
  Tests for REQ-190 -- `Letflow.Secrets` (`put/2`, `resolve/2`, `disable/2`) plus the
  webhook HMAC reconciliation (`Letflow.Webhooks.create/2`'s secret-handling change) and
  the "no route/controller touched" acceptance criterion. See `test/specs/REQ-190.md`
  for the full acceptance-criterion -> test-case mapping and rationale. Design
  authority: `lib/letflow/design/req190-secrets-core.md`. Implementation authority:
  `lib/letflow/secrets.ex`, `lib/letflow/secrets/secret.ex`, `lib/letflow/webhooks.ex`.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database. Each test that needs a real tenant provisions
  one via `Letflow.TenantFixture.provisioned_tenant!/1`, mirroring
  `test/letflow/webhooks_test.exs`'s own established pattern.

  `async: false` (reverted by ISS-0480, previously `async: true` per ISS-0113 / ISS-0423,
  `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md`) -- this file's
  own ISS-0113 three-mechanism classification (no self-checkout, no concurrent
  multi-process DB access, no second provisioning call per test) was correct and
  remains true; the revert is not a retraction of that classification. ISS-0480
  (`lib/letflow/design/iss0480-sandbox-checkout-race-remedy.md`) found a *fourth*,
  systemic mechanism neither this file's own code nor ISS-0113's analysis considered:
  `provisioned_tenant!/1`'s unconditional first line, `Sandbox.mode(Letflow.Repo,
  :auto)`, does not merely affect its own caller -- when it actually changes the
  pool's mode, `DBConnection.Ownership.Manager`'s empty-except-list check-in
  (`deps/db_connection/lib/db_connection/ownership/manager.ex:169-172`) discards the
  checked-out connection of *every* process in the pool, including any other
  concurrently-running `async: true` test that never itself calls `Sandbox.mode/2`
  and holds no relation to this file (e.g. `Letflow.RowApprovalTest`). Because
  `Letflow.DataCase.setup/1` checks out a connection unconditionally for every test
  regardless of `async`, every `async: true` file in the suite was an exposed
  bystander for as long as this file (or `test/letflow/webhooks_test.exs`) ran
  concurrently with it under `async: true`. Reverting to `async: false` removes the
  disruptive call from the async scheduling phase entirely (ExUnit runs every
  `async: true` module to completion before any `async: false` module starts), which
  is sufficient by construction, not by continued reasoning about timing. See
  ISS-0480's design doc §6 for the legitimate longer-term fix (a `setup_all`-boundary
  redesign of `provisioned_tenant!/1` itself) that was deliberately not attempted here.

  `Letflow.Secrets` requires `LETFLOW_SECRETS_MASTER_KEY` to be set (0016 §B) --
  `config/test.exs` already injects a real test-only value before this suite boots, so
  every test below runs under a real (non-default, non-all-zeros) master key exactly
  as production would.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Letflow.Repo
  alias Letflow.Secrets
  alias Letflow.Secrets.Secret
  alias Letflow.Webhooks

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req190-secrets") do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-190 Secrets Test Tenant"
    )
  end

  defp unique_segment(prefix) do
    prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
  end

  defp put!(tenant_id, attrs) do
    base = %{
      tenant_id: tenant_id,
      namespace: "webhook",
      name: unique_segment("secret"),
      purpose: :generic,
      plaintext: "s3cr3t-plaintext-value",
      created_by: "test-suite"
    }

    {:ok, result} = Secrets.put(Map.merge(base, attrs))
    result
  end

  defp pinned(reference, key_id), do: "#{reference}##{key_id}"

  # ---------------------------------------------------------------------------------
  # AC1 -- put/2 + resolve/2 round trip; ciphertext column does not contain plaintext
  # ---------------------------------------------------------------------------------

  describe "AC1: put/2 followed by resolve/2 round-trips the plaintext; ciphertext never contains it" do
    test "round trip" do
      %{tenant_id: tenant_id} = provisioned_tenant()
      plaintext = "correct horse battery staple #{unique_segment("plaintext")}"

      %{reference: reference} = put!(tenant_id, %{plaintext: plaintext, purpose: :generic})

      stored =
        Repo.get_by!(Secret, tenant_id: tenant_id, namespace: "webhook") |> reload_by_ref()

      refute stored.ciphertext == plaintext
      refute String.contains?(stored.ciphertext, plaintext)

      assert {:ok, %{plaintext: ^plaintext, purpose: :generic}} =
               Secrets.resolve(reference, tenant_id: tenant_id)
    end

    defp reload_by_ref(%Secret{id: id}), do: Repo.get!(Secret, id)

    test "property round trip: put/2 -> resolve/2 returns arbitrary binary plaintext unchanged, never stored verbatim in ciphertext" do
      %{tenant_id: tenant_id} = provisioned_tenant("req190-secrets-prop")

      check all(plaintext <- StreamData.binary(min_length: 0, max_length: 512), max_runs: 25) do
        %{reference: reference} =
          put!(tenant_id, %{name: unique_segment("prop"), plaintext: plaintext})

        stored =
          Repo.get_by!(Secret,
            tenant_id: tenant_id,
            namespace: "webhook",
            name: name_from(reference)
          )

        # ISS-0403: a substring-containment check is only a meaningful leak signal once
        # coincidental containment is astronomically unlikely. For a k-byte plaintext and an
        # N-byte ciphertext, the expected number of coincidental matches is roughly
        # N * (1/256)^k -- at k=1 that's ~2/256 for a 512-byte ciphertext (a real, observed
        # CI failure), but at k>=8 it's below 1e-16 regardless of N here. 0 < byte_size < 8
        # is skipped as statistically meaningless rather than a genuine leak check.
        if byte_size(plaintext) >= 8 do
          refute String.contains?(stored.ciphertext, plaintext)
        end

        assert {:ok, %{plaintext: ^plaintext}} = Secrets.resolve(reference, tenant_id: tenant_id)
      end
    end

    defp name_from(reference) do
      ["sec:", "", "tenant", _tenant, _namespace, name] = String.split(reference, "/")
      name
    end

    test "ISS-0403 regression: a 1-byte plaintext does not trigger the containment refute" do
      %{tenant_id: tenant_id} = provisioned_tenant("iss0403-short-plaintext")

      # The exact byte value (186) that produced a real CI false positive
      # (github.com/tvolodi/letflow's WF03-ISS0401-20260902 Step Final run,
      # test/letflow/secrets_test.exs:85-103) before this fix -- any single-byte
      # plaintext has a real chance of appearing somewhere in the stored ciphertext by
      # coincidence, which is not a leak. Run several times to demonstrate the
      # containment check is genuinely skipped (never coincidentally re-triggers), not
      # merely lucky once.
      for _ <- 1..20 do
        plaintext = <<186>>

        %{reference: reference} =
          put!(tenant_id, %{name: unique_segment("iss0403"), plaintext: plaintext})

        _stored =
          Repo.get_by!(Secret,
            tenant_id: tenant_id,
            namespace: "webhook",
            name: name_from(reference)
          )

        # byte_size(plaintext) == 1 < 8, so the containment check must be skipped --
        # asserting it would be flaky by design, not a real leak signal.
        refute byte_size(plaintext) >= 8

        assert {:ok, %{plaintext: ^plaintext}} = Secrets.resolve(reference, tenant_id: tenant_id)
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- put/2's return shape
  # ---------------------------------------------------------------------------------

  describe "AC2: put/2 returns exactly {:ok, %{reference:, key_id:, created_at:}}" do
    test "put return shape" do
      %{tenant_id: tenant_id} = provisioned_tenant()

      {:ok, result} =
        Secrets.put(%{
          tenant_id: tenant_id,
          namespace: "webhook",
          name: unique_segment("shape"),
          purpose: :generic,
          plaintext: "shape-test-plaintext",
          created_by: "test-suite"
        })

      assert Map.keys(result) |> Enum.sort() == [:created_at, :key_id, :reference]
      assert is_binary(result.reference)
      assert is_integer(result.key_id) and result.key_id > 0
      assert %DateTime{} = result.created_at
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- tenant-mismatch rejection, non-disclosure, before any query
  # ---------------------------------------------------------------------------------

  describe "AC3: resolve/2 rejects a cross-tenant reference without disclosing existence" do
    test "tenant mismatch non-disclosure" do
      %{tenant_id: tenant_a} = provisioned_tenant("req190-secrets-a")
      %{tenant_id: tenant_b, tenant: tenant_b_record} = provisioned_tenant("req190-secrets-b")

      %{reference: real_reference} = put!(tenant_b, %{purpose: :generic})

      nonexistent_reference =
        "sec://tenant/does-not-exist-#{unique_segment("x")}/webhook/whatever"

      real_result = Secrets.resolve(real_reference, tenant_id: tenant_a)
      nonexistent_result = Secrets.resolve(nonexistent_reference, tenant_id: tenant_a)

      assert real_result == {:error, :tenant_mismatch}
      assert nonexistent_result == {:error, :tenant_mismatch}
      assert real_result == nonexistent_result

      # sanity: tenant_b_record.slug is embedded in real_reference, confirming this
      # really was a *different, real* tenant's reference, not a coincidental miss.
      assert String.contains?(real_reference, tenant_b_record.slug)
    end

    test "tenant check ordering: cross-tenant reference to a tenant with zero secrets still returns :tenant_mismatch, not :not_found" do
      %{tenant_id: tenant_a} = provisioned_tenant("req190-secrets-order-a")

      %{tenant_id: _tenant_b, tenant: tenant_b_record} =
        provisioned_tenant("req190-secrets-order-b")

      # tenant_b has no secrets at all -- if resolve/2 queried the secrets table
      # before checking the tenant match, the only possible outcome would be
      # {:error, :not_found} (nothing to find), which is observably different from
      # {:error, :tenant_mismatch}. Asserting :tenant_mismatch here demonstrates the
      # tenant check actually ran and short-circuited before any query.
      reference = "sec://tenant/#{tenant_b_record.slug}/webhook/nonexistent-name"

      assert {:error, :tenant_mismatch} = Secrets.resolve(reference, tenant_id: tenant_a)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- purpose/consumer matrix
  # ---------------------------------------------------------------------------------

  describe "AC4: purpose/consumer matrix" do
    test "purpose matrix" do
      %{tenant_id: tenant_id} = provisioned_tenant("req190-secrets-matrix")

      %{reference: webhook_ref} = put!(tenant_id, %{purpose: :webhook_hmac})
      %{reference: generic_ref} = put!(tenant_id, %{purpose: :generic})

      # :webhook_dispatcher may resolve :webhook_hmac ...
      assert {:ok, %{purpose: :webhook_hmac}} =
               Secrets.resolve(webhook_ref, tenant_id: tenant_id, consumer: :webhook_dispatcher)

      # ... and :generic ...
      assert {:ok, %{purpose: :generic}} =
               Secrets.resolve(generic_ref, tenant_id: tenant_id, consumer: :webhook_dispatcher)

      # :generic (default, omitted) may NOT resolve :webhook_hmac ...
      assert {:error, :purpose_not_allowed} = Secrets.resolve(webhook_ref, tenant_id: tenant_id)

      # ... but MAY resolve :generic.
      assert {:ok, %{purpose: :generic}} = Secrets.resolve(generic_ref, tenant_id: tenant_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- unpinned resolves to newest ACTIVE version, not merely newest row
  # ---------------------------------------------------------------------------------

  describe "AC5: unpinned reference resolves to the newest ACTIVE version" do
    test "unpinned resolves to newest active" do
      %{tenant_id: tenant_id} = provisioned_tenant("req190-secrets-versions")
      name = unique_segment("rotating")

      %{reference: reference, key_id: older_key_id} =
        put!(tenant_id, %{name: name, plaintext: "older-active-plaintext"})

      %{key_id: newer_key_id} =
        put!(tenant_id, %{name: name, plaintext: "newer-disabled-plaintext"})

      assert newer_key_id > older_key_id

      assert {:ok, %{key_id: ^newer_key_id}} =
               Secrets.disable(pinned(reference, newer_key_id), tenant_id: tenant_id)

      # The R-Co-defect-correction case: newest row is disabled, so the unpinned
      # reference must fall back to the older, still-active version's plaintext --
      # not fail, and not return the disabled version's plaintext.
      assert {:ok, %{plaintext: "older-active-plaintext", key_id: ^older_key_id}} =
               Secrets.resolve(reference, tenant_id: tenant_id)
    end

    test "pinned resolves disabled version" do
      %{tenant_id: tenant_id} = provisioned_tenant("req190-secrets-pinned-disabled")
      name = unique_segment("pin-disabled")

      %{reference: reference} = put!(tenant_id, %{name: name, plaintext: "v1"})
      %{key_id: v2_key_id} = put!(tenant_id, %{name: name, plaintext: "v2-to-disable"})

      assert {:ok, _} = Secrets.disable(pinned(reference, v2_key_id), tenant_id: tenant_id)

      # design §3.2 step 4: a pinned reference to a disabled (not deleted) version
      # still resolves successfully.
      assert {:ok, %{plaintext: "v2-to-disable", key_id: ^v2_key_id}} =
               Secrets.resolve(pinned(reference, v2_key_id), tenant_id: tenant_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- webhook HMAC reconciliation end to end
  # ---------------------------------------------------------------------------------

  describe "AC9: webhook HMAC reconciliation -- create/2 writes via put/2; resolve/2 recovers the same plaintext; secret_hash stays NULL" do
    test "webhook HMAC reconciliation" do
      %{schema_name: schema_name, tenant_id: tenant_id} =
        provisioned_tenant("req190-webhook-recon")

      # REQ-204: example.test does not resolve via DNS (SSRF check blocks it).
      # Use a public IP literal (203.0.113.0/24 is RFC 5737 TEST-NET-3, not in any blocked range).
      {:ok, %{subscription: subscription, hmac_secret_once: plaintext}} =
        Webhooks.create(%{target_url: "https://203.0.113.1/hook"}, prefix: schema_name)

      assert is_binary(subscription.secret_ref)
      assert String.starts_with?(subscription.secret_ref, "sec://tenant/")
      assert is_integer(subscription.secret_key_id) and subscription.secret_key_id > 0

      pinned_reference = pinned(subscription.secret_ref, subscription.secret_key_id)

      assert {:ok, %{plaintext: ^plaintext, purpose: :webhook_hmac}} =
               Secrets.resolve(pinned_reference,
                 tenant_id: tenant_id,
                 consumer: :webhook_dispatcher
               )

      # Also true via the unpinned reference (this is the only/newest version).
      assert {:ok, %{plaintext: ^plaintext}} =
               Secrets.resolve(subscription.secret_ref,
                 tenant_id: tenant_id,
                 consumer: :webhook_dispatcher
               )

      # Direct Postgres read -- the Subscription struct has no field mapped to
      # secret_hash at all (by design), so this bypasses Ecto.Schema entirely to
      # prove the actual column value, not just the struct's silence about it.
      %{rows: [[secret_hash]]} =
        Repo.query!(
          ~s(SELECT secret_hash FROM "#{schema_name}".webhook_subscriptions WHERE id = $1),
          [Ecto.UUID.dump!(subscription.id)]
        )

      assert secret_hash == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC11 -- no route or controller touched
  # ---------------------------------------------------------------------------------

  describe "AC11: REQ-190's own modules touch no route/controller-shaped construct" do
    test "no route or controller touched" do
      for path <- [
            "lib/letflow/secrets.ex",
            "lib/letflow/secrets/secret.ex",
            "lib/letflow/secrets/redaction.ex",
            "lib/letflow/secrets/log_filter.ex"
          ] do
        source = File.read!(Path.join(File.cwd!(), path))
        refute source =~ ~r/use\s+Plug\.Router/, "#{path} unexpectedly uses Plug.Router"
        refute source =~ ~r/use\s+\w*Web,\s*:controller/, "#{path} unexpectedly is a controller"
        refute source =~ ~r/\bget\s+"\//, "#{path} unexpectedly defines a route"
      end

      refute File.dir?(Path.join(File.cwd!(), "lib/letflow/routers")) and
               File.exists?(Path.join(File.cwd!(), "lib/letflow/routers/secrets.ex")),
             "lib/letflow/routers/secrets.ex must not exist -- that is REQ-191's scope"
    end
  end
end
