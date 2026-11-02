defmodule Letflow.Identity.TenantUpdateChangesetRemovedTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 12 item 17(0) and section 3.1 guard (0) (A2 only; spec
  `test/specs/ISS-0993-A2.md`): `Letflow.Identity.Tenant.update_changeset/2` was a dead second
  writer of `status` (it cast `status`, and nothing under `lib/` called it). A2 deleted it so that
  the only status writers are `Identity.set_tenant_status/2` (which carries the platform-tenant
  deactivation guard) and `TenantOnboarding` (`:active`). This file makes sure a second status
  writer cannot reappear unnoticed:

    * `Tenant.update_changeset` is not defined (any arity) and the source of `tenant.ex` has no
      `def update_changeset`;
    * no file under `lib/` (design docs excluded) references `update_changeset` for the Tenant
      schema (a `Tenant.update_changeset` call, or an alias-free `update_changeset` call inside
      `tenant.ex`);
    * every `Tenant.status_changeset` caller under `lib/` is `Identity.set_tenant_status/2` (the
      private `set_tenant_status/2` in `lib/letflow/identity.ex`) or
      `lib/letflow/tenant_onboarding.ex`.

  No database. `async: false` is not needed (read-only, no global state) but is harmless.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Identity.Tenant

  @tenant_source "lib/letflow/identity/tenant.ex"

  # Source lines with doc heredocs and comment lines removed, as {number, line}.
  defp code_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, number}, {in_doc?, acc} ->
      quotes = length(String.split(line, ~s(""")) |> tl())
      toggled? = rem(quotes, 2) == 1

      cond do
        in_doc? -> {not toggled?, acc}
        toggled? -> {true, acc}
        String.starts_with?(String.trim_leading(line), "#") -> {false, acc}
        true -> {false, [{number, line} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp lib_files do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "lib/letflow/design/"))
  end

  describe "Tenant.update_changeset is gone" do
    test "the module is loaded and exports no update_changeset of any arity" do
      assert Code.ensure_loaded?(Tenant)

      exported = Tenant.__info__(:functions)

      refute Enum.any?(exported, fn {name, _arity} -> name == :update_changeset end),
             "Tenant still exports update_changeset: #{inspect(exported)}"

      # the changesets that must remain (the scan is not vacuous)
      for {name, arity} <- [
            create_changeset: 3,
            admin_patch_changeset: 2,
            status_changeset: 2,
            settings_changeset: 2
          ] do
        assert function_exported?(Tenant, name, arity), "#{name}/#{arity} must still exist"
      end
    end

    test "tenant.ex source defines no update_changeset" do
      offenders =
        for {number, line} <- code_lines(@tenant_source),
            line =~ ~r/\bupdate_changeset\b/,
            do: "#{@tenant_source}:#{number}"

      assert offenders == []
    end

    test "no file under lib/ references update_changeset for the Tenant schema" do
      offenders =
        for file <- lib_files(),
            {number, line} <- code_lines(file),
            line =~ ~r/Tenant\.update_changeset/,
            do: "#{file}:#{number}"

      assert offenders == []
    end
  end

  describe "the status writers of a tenant" do
    test "every Tenant.status_changeset caller under lib/ is set_tenant_status/2 or TenantOnboarding" do
      callers =
        for file <- lib_files(),
            {number, line} <- code_lines(file),
            line =~ ~r/Tenant\.status_changeset\(/,
            do: {file, number}

      files = callers |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert files == ["lib/letflow/identity.ex", "lib/letflow/tenant_onboarding.ex"]

      # inside identity.ex the single call sits in defp set_tenant_status/2
      identity = File.read!("lib/letflow/identity.ex")
      [_before, tail] = String.split(identity, "defp set_tenant_status(", parts: 2)
      [function_body, _rest] = String.split(tail, ~r/\n  (def|defp|@doc|@spec) /, parts: 2)

      assert function_body =~ "Tenant.status_changeset("

      identity_calls =
        Enum.filter(callers, fn {file, _n} -> file == "lib/letflow/identity.ex" end)

      assert length(identity_calls) == 1

      # TenantOnboarding writes only :active
      onboarding_lines =
        for {_number, line} <- code_lines("lib/letflow/tenant_onboarding.ex"),
            line =~ ~r/status_changeset\(/,
            do: line

      assert onboarding_lines != []

      assert Enum.all?(onboarding_lines, &(&1 =~ ":active")),
             "TenantOnboarding must write only :active: #{inspect(onboarding_lines)}"
    end
  end
end
