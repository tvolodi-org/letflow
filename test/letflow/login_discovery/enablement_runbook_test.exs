defmodule Letflow.LoginDiscovery.EnablementRunbookTest do
  @moduledoc """
  REQ-444 criterion 3 (spec `test/specs/REQ-444.md`): the rotation runbook exists
  (repository test, REQ-443 dependency) and the enablement runbook has its structure
  and holds no secret.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @rotation "docs/runbooks/login-directory-pepper-rotation.md"
  @enablement "docs/runbooks/login-directory-enablement.md"
  @hex64 ~r/(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])/
  @printer ~r/\b(echo|printenv|cat|type|Get-Content|Write-Host)\b/

  test "the pepper-rotation runbook exists and is non-trivial" do
    assert File.regular?(@rotation)
    assert File.read!(@rotation) =~ ~r/^## 2\. Planned rotation/m
  end

  test "REQ-443 is in REQ-444's depends_on (docs/requirements.yaml)" do
    yaml =
      "docs/requirements.yaml"
      |> File.read!()
      |> String.replace(<<13, 10>>, <<10>>)

    [_, rest] = String.split(yaml, "\n  - id: REQ-444\n", parts: 2)
    [entry | _] = String.split(rest, "\n  - id: REQ-445\n", parts: 2)
    [_, deps] = Regex.run(~r/^    depends_on:\s*\[([^\]]*)\]/m, entry)
    assert "REQ-443" in Enum.map(String.split(deps, ","), &String.trim/1)
  end

  describe "the enablement runbook" do
    setup do
      {:ok, text: File.read!(@enablement)}
    end

    test "exists with its sections, the order of operations and the rotation cross-link", %{
      text: text
    } do
      assert text =~ ~r/^# Runbook: enabling email-first login/m
      assert text =~ ~r/^## A\. Checked at boot/m
      assert text =~ ~r/^## B\. Only documented/m
      assert text =~ ~r/^## Order of operations/m
      assert text =~ @rotation
      assert File.regular?(@rotation)
    end

    test "names the gate's variables and marks the marker ADVISORY", %{text: text} do
      for name <- [
            "LETFLOW_LOGIN_DIRECTORY_LEGAL_CONFIRMATION",
            "LETFLOW_MAIL_ADAPTER",
            "LETFLOW_TRUSTED_PROXIES",
            "LETFLOW_LOGIN_DISCOVERY_ENABLED",
            "VITE_EMAIL_FIRST_LOGIN",
            "Letflow.LoginDiscovery.BootCheck"
          ] do
        assert text =~ name, "runbook does not mention #{name}"
      end

      assert text =~ "ADVISORY"
      assert text =~ "CHECKED AT BOOT"
      assert text =~ "ONLY DOCUMENTED"
    end

    test "contains no 64-hex string (no secret value); the regex can fail", %{text: text} do
      refute text =~ @hex64
      assert String.duplicate("a1", 32) =~ @hex64
      assert String.upcase(String.duplicate("a1", 32)) =~ @hex64
      refute String.duplicate("a1", 31) <> "a" =~ @hex64
    end

    test "no line pairs a printing command with a secret variable or expands one", %{text: text} do
      for line <- String.split(text, ~r/\r?\n/) do
        refute line =~ @printer and line =~ ~r/PEPPER|SECRET|PASSWORD|MASTER_KEY|CONFIRMATION/,
               "runbook line prints a secret: #{line}"

        refute line =~ ~r/\$\{?LETFLOW_[A-Z_]*(PEPPER|SECRET|PASSWORD|MASTER_KEY|CONFIRMATION)/,
               "runbook line expands a secret variable: #{line}"

        refute line =~ ~r/\$env:LETFLOW_[A-Z_]*(PEPPER|SECRET|PASSWORD|MASTER_KEY|CONFIRMATION)/i
      end
    end
  end
end
