defmodule Letflow.Api.RolesMatrixParityTest do
  @moduledoc """
  REQ-448 AC (`lib/letflow/design/req448-tenant-auditor-role.md` sections 6.1-6.3;
  spec `test/specs/REQ-448.md`): the fenced matrix block of `docs/roles.md` and the code
  (`Letflow.Api.Authorization`) must agree, cell for cell and in the scope column.

  The parser is strict (header of 1 + 8 + 1 tokens, every row of 10 tokens, cells exactly
  `yes`/`no`, scope exactly `platform`/`tenant`, no duplicate permission). The comparator
  reports violations as tuples; the mutation tests operate on an in-memory copy of the file
  text and prove that a single-cell flip, a scope flip, a missing row, an extra row, a swapped
  header, a duplicate row, a malformed cell and a short row are each detected. Nothing here
  writes a file.

  `PLATFORM_ADMIN` is evaluated as the platform tenant sees it
  (`has_permission_in_scope?([:PLATFORM_ADMIN], p, true)`); `role_allows?(:PLATFORM_ADMIN, _)`
  is a vacuous `true` and would hide a wrong cell.

  Pure (reads one file, calls pure functions): `async: true` is safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization

  @roles_md Path.expand("../../../docs/roles.md", __DIR__)

  # Decision 0046 D6: exactly 14 atoms. :PromotionsRead was withheld by REQ-448 until Q-1011's
  # stored-tenant check merged and was granted by ISS-1109 / GH #2489. :MyModulesRead is the
  # role-agnostic grant every role holds.
  @auditor_yes_literal [
    :DefinitionsRead,
    :InstancesRead,
    :TasksRead,
    :AuditRead,
    :MetricsRead,
    :AttachmentsRead,
    :EntitiesDefinitionsRead,
    :EntitiesQuery,
    :EntitiesAggregate,
    :EntitiesAttachmentsRead,
    :HelpRead,
    :MembershipsRead,
    :PromotionsRead,
    :MyModulesRead
  ]

  # --- parser --------------------------------------------------------------------------------

  defp role_names, do: Enum.map(Authorization.roles(), &Atom.to_string/1)

  defp matrix_lines(text) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))

    case Enum.drop_while(lines, &(&1 != "## Matrix")) do
      [] ->
        {:error, :no_matrix_block}

      [_heading | after_heading] ->
        case Enum.drop_while(after_heading, &(not String.starts_with?(&1, "```"))) do
          [] ->
            {:error, :no_matrix_block}

          [_open | in_block] ->
            {block, rest} = Enum.split_while(in_block, &(not String.starts_with?(&1, "```")))
            if rest == [], do: {:error, :no_matrix_block}, else: {:ok, block}
        end
    end
  end

  # {:ok, %{header: [String.t()], rows: [row]}} | {:error, reason}; the first malformation wins.
  defp parse(text) do
    with {:ok, [header_line | row_lines]} <- matrix_lines(text),
         expected = ["permission"] ++ role_names() ++ ["scope"],
         actual = String.split(header_line),
         :ok <-
           if(actual == expected, do: :ok, else: {:error, {:header_mismatch, expected, actual}}),
         {:ok, rows} <- parse_rows(row_lines, role_names()) do
      {:ok, %{header: actual, rows: rows}}
    else
      {:ok, []} -> {:error, :no_matrix_block}
      {:error, _reason} = error -> error
    end
  end

  defp parse_rows(lines, roles) do
    lines
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case parse_row(line, roles) do
        {:ok, row} ->
          if Enum.any?(acc, &(&1.permission == row.permission)),
            do: {:halt, {:error, {:duplicate_row, row.permission}}},
            else: {:cont, {:ok, [row | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp parse_row(line, roles) do
    tokens = String.split(line)
    width = length(roles) + 2

    if length(tokens) != width do
      {:error, {:bad_row_width, line, length(tokens)}}
    else
      [permission | rest] = tokens
      {cells, [scope]} = Enum.split(rest, length(roles))

      with {:ok, bools} <- parse_cells(permission, Enum.zip(roles, cells)),
           {:ok, scope_atom} <- parse_scope(permission, scope) do
        {:ok,
         %{
           permission: permission,
           cells: Map.new(Enum.zip(roles, bools)),
           scope: scope_atom
         }}
      end
    end
  end

  defp parse_cells(permission, pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      {_role, "yes"}, {:ok, acc} -> {:cont, {:ok, [true | acc]}}
      {_role, "no"}, {:ok, acc} -> {:cont, {:ok, [false | acc]}}
      {role, raw}, _acc -> {:halt, {:error, {:bad_cell, permission, role, raw}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_scope(_permission, "platform"), do: {:ok, :platform}
  defp parse_scope(_permission, "tenant"), do: {:ok, :tenant}
  defp parse_scope(permission, raw), do: {:error, {:bad_scope, permission, raw}}

  # --- comparator ----------------------------------------------------------------------------

  # The permission atoms come from core_permissions/0, never from String.to_existing_atom/1 on
  # file input.
  defp code_by_name, do: Map.new(Authorization.core_permissions(), &{Atom.to_string(&1), &1})

  defp code_cell(:PLATFORM_ADMIN, permission),
    do: Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, true)

  defp code_cell(role, permission), do: Authorization.role_allows?(role, permission)

  defp compare(%{rows: rows}) do
    by_name = code_by_name()
    doc_names = Enum.map(rows, & &1.permission)

    missing =
      for name <- Enum.sort(Map.keys(by_name)), name not in doc_names, do: {:missing_row, name}

    extra =
      for name <- doc_names, not Map.has_key?(by_name, name), do: {:extra_row, name}

    cell_and_scope =
      rows
      |> Enum.filter(&Map.has_key?(by_name, &1.permission))
      |> Enum.flat_map(fn row ->
        permission = Map.fetch!(by_name, row.permission)

        cells =
          Enum.flat_map(Authorization.roles(), fn role ->
            doc = Map.fetch!(row.cells, Atom.to_string(role))
            code = code_cell(role, permission)

            if doc == code,
              do: [],
              else: [{:cell_mismatch, row.permission, Atom.to_string(role), doc, code}]
          end)

        code_scope = Authorization.permission_scope(permission)

        scope =
          if row.scope == code_scope,
            do: [],
            else: [{:scope_mismatch, row.permission, row.scope, code_scope}]

        cells ++ scope
      end)

    doc_platform = for row <- rows, row.scope == :platform, do: row.permission
    code_platform = Enum.map(Authorization.platform_permissions(), &Atom.to_string/1)

    platform_set =
      if Enum.sort(doc_platform) == Enum.sort(code_platform),
        do: [],
        else: [{:platform_set_mismatch, Enum.sort(doc_platform), Enum.sort(code_platform)}]

    missing ++ extra ++ cell_and_scope ++ platform_set
  end

  # All violations for a file text: a parse error is the single violation.
  defp violations(text) do
    case parse(text) do
      {:ok, matrix} -> compare(matrix)
      {:error, reason} -> [{:parse_error, reason}]
    end
  end

  # --- in-memory mutation helpers --------------------------------------------------------------

  # The violations a mutation ADDS on top of whatever the unmutated file already has, so a mutation
  # test stays about its own mutation and does not also fail when the real file is out of step
  # (that is the job of the single "has no violations" test).
  defp new_violations(mutated), do: violations(mutated) -- violations(real_text())

  defp real_text, do: File.read!(@roles_md)

  # Replaces token `index` (0-based) of the matrix row for `permission`, preserving whitespace.
  defp replace_token(text, permission, index, new_value) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      if String.starts_with?(line, permission <> " ") do
        line
        |> String.split(~r/(\s+)/, include_captures: true)
        |> List.replace_at(index * 2, new_value)
        |> Enum.join()
      else
        line
      end
    end)
    |> Enum.join("\n")
  end

  defp role_column(role), do: 1 + Enum.find_index(role_names(), &(&1 == role))
  defp scope_column, do: 1 + length(role_names())

  defp remove_row(text, permission) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, permission <> " "))
    |> Enum.join("\n")
  end

  # Inserts `line` right after the header line of the matrix block.
  defp insert_after_header(text, line) do
    {before, [header | rest]} =
      text
      |> String.split("\n")
      |> Enum.split_while(&(not String.starts_with?(&1, "permission ")))

    Enum.join(before ++ [header, line] ++ rest, "\n")
  end

  defp row_line(text, permission) do
    text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, permission <> " "))
  end

  defp yes_names(matrix_rows, role),
    do: for(row <- matrix_rows, row.cells[role], do: row.permission)

  # --- the real file -----------------------------------------------------------------------------

  describe "the repository's docs/roles.md" do
    test "has no violations against the code: header, one row per core permission, every cell, the scope column" do
      assert {:ok, %{header: header, rows: rows}} = parse(real_text())

      assert length(header) == length(Authorization.roles()) + 2
      assert length(rows) == length(Authorization.core_permissions())

      cells = for row <- rows, {_role, _value} <- row.cells, do: :cell

      assert length(cells) ==
               length(Authorization.core_permissions()) * length(Authorization.roles())

      assert violations(real_text()) == []
    end

    test "has exactly the core permissions: PlatformServicesManage (platform) and AttachmentLinksIssue (tenant) are present" do
      {:ok, %{rows: rows}} = parse(real_text())
      by_name = Map.new(rows, &{&1.permission, &1})

      assert Enum.sort(Map.keys(by_name)) ==
               Enum.sort(Enum.map(Authorization.core_permissions(), &Atom.to_string/1))

      assert by_name["PlatformServicesManage"].scope == :platform
      assert by_name["AttachmentLinksIssue"].scope == :tenant

      # PlatformServicesManage: PLATFORM_ADMIN only.
      assert yes_names([by_name["PlatformServicesManage"]], "PLATFORM_ADMIN") ==
               ["PlatformServicesManage"]

      for role <- role_names() -- ["PLATFORM_ADMIN"] do
        refute by_name["PlatformServicesManage"].cells[role], role
      end

      # AttachmentLinksIssue: exactly the five roles that reached the link route before REQ-448.
      holders = for {role, true} <- by_name["AttachmentLinksIssue"].cells, do: role

      assert Enum.sort(holders) ==
               Enum.sort([
                 "PLATFORM_ADMIN",
                 "PROCESS_DESIGNER",
                 "PROCESS_OPERATOR",
                 "TASK_WORKER",
                 "TENANT_ADMIN"
               ])
    end

    test "every role in roles/0 has a column and every column is a role in roles/0" do
      {:ok, %{header: header, rows: rows}} = parse(real_text())
      columns = header |> Enum.drop(1) |> Enum.drop(-1)

      assert columns == role_names()
      assert List.last(columns) == "TENANT_AUDITOR"

      for row <- rows do
        assert Enum.sort(Map.keys(row.cells)) == Enum.sort(role_names()), row.permission
      end
    end

    test "the TENANT_AUDITOR column is exactly the 14 literal atoms of D6, PromotionsRead included" do
      {:ok, %{rows: rows}} = parse(real_text())

      assert Enum.sort(yes_names(rows, "TENANT_AUDITOR")) ==
               Enum.sort(Enum.map(@auditor_yes_literal, &Atom.to_string/1))

      assert length(@auditor_yes_literal) == 14

      # and the code agrees with the same literal (not only with the doc)
      granted =
        Enum.filter(
          Authorization.core_permissions(),
          &Authorization.role_allows?(:TENANT_AUDITOR, &1)
        )

      assert Enum.sort(granted) == Enum.sort(@auditor_yes_literal)
    end

    test "PromotionsRead is yes for TENANT_AUDITOR, TENANT_ADMIN and PLATFORM_ADMIN (the grant is pinned)" do
      {:ok, %{rows: rows}} = parse(real_text())
      row = Enum.find(rows, &(&1.permission == "PromotionsRead"))

      assert row.cells["TENANT_AUDITOR"]
      assert row.cells["TENANT_ADMIN"]
      assert row.cells["PLATFORM_ADMIN"]

      assert Authorization.role_allows?(:TENANT_AUDITOR, :PromotionsRead)
      assert Authorization.role_allows?(:TENANT_ADMIN, :PromotionsRead)
      assert Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], :PromotionsRead, true)
    end
  end

  # --- the comparator is not vacuous ---------------------------------------------------------------

  describe "mutations of an in-memory copy are detected" do
    test "sanity: the mutation helpers change exactly the intended token and nothing else" do
      text = real_text()
      mutated = replace_token(text, "AuditRead", role_column("TENANT_AUDITOR"), "no")

      assert mutated != text
      assert String.split(mutated, "\n") |> length() == String.split(text, "\n") |> length()

      diff =
        Enum.zip(String.split(text, "\n"), String.split(mutated, "\n"))
        |> Enum.reject(fn {a, b} -> a == b end)

      assert [{old, new}] = diff
      assert String.starts_with?(old, "AuditRead ")
      assert String.split(old) -- String.split(new) == ["yes"]
      assert length(String.split(old)) == length(String.split(new))
    end

    test "flipping one cell is detected: TENANT_AUDITOR / AuditRead yes -> no" do
      mutated = replace_token(real_text(), "AuditRead", role_column("TENANT_AUDITOR"), "no")

      assert new_violations(mutated) == [
               {:cell_mismatch, "AuditRead", "TENANT_AUDITOR", false, true}
             ]
    end

    test "flipping one cell is detected: PROCESS_OPERATOR / TenantsManage no -> yes (the permissive side)" do
      mutated =
        replace_token(real_text(), "TenantsManage", role_column("PROCESS_OPERATOR"), "yes")

      assert new_violations(mutated) == [
               {:cell_mismatch, "TenantsManage", "PROCESS_OPERATOR", true, false}
             ]
    end

    test "flipping the TENANT_AUDITOR / PromotionsRead cell to no is detected (the grant cannot be undone in the doc alone)" do
      mutated = replace_token(real_text(), "PromotionsRead", role_column("TENANT_AUDITOR"), "no")

      assert new_violations(mutated) == [
               {:cell_mismatch, "PromotionsRead", "TENANT_AUDITOR", false, true}
             ]
    end

    test "flipping the PLATFORM_ADMIN / TenantsManage cell is detected through the platform-tenant evaluation" do
      mutated = replace_token(real_text(), "TenantsManage", role_column("PLATFORM_ADMIN"), "no")

      assert new_violations(mutated) == [
               {:cell_mismatch, "TenantsManage", "PLATFORM_ADMIN", false, true}
             ]
    end

    test "flipping the TENANT_ADMIN / TenantsManage cell to yes is detected (TENANT_ADMIN never holds a platform permission)" do
      mutated = replace_token(real_text(), "TenantsManage", role_column("TENANT_ADMIN"), "yes")

      assert new_violations(mutated) == [
               {:cell_mismatch, "TenantsManage", "TENANT_ADMIN", true, false}
             ]
    end

    test "flipping the new AttachmentLinksIssue / TENANT_AUDITOR cell to yes is detected" do
      mutated =
        replace_token(real_text(), "AttachmentLinksIssue", role_column("TENANT_AUDITOR"), "yes")

      assert new_violations(mutated) == [
               {:cell_mismatch, "AttachmentLinksIssue", "TENANT_AUDITOR", true, false}
             ]
    end

    test "flipping one scope cell is detected: TenantsManage platform -> tenant" do
      mutated = replace_token(real_text(), "TenantsManage", scope_column(), "tenant")
      found = violations(mutated)

      assert {:scope_mismatch, "TenantsManage", :tenant, :platform} in found
      assert Enum.any?(found, &match?({:platform_set_mismatch, _, _}, &1))
      refute Enum.any?(found, &match?({:cell_mismatch, _, _, _, _}, &1))
    end

    test "flipping one scope cell is detected: AuditRead tenant -> platform" do
      mutated = replace_token(real_text(), "AuditRead", scope_column(), "platform")

      assert {:scope_mismatch, "AuditRead", :platform, :tenant} in violations(mutated)
    end

    test "a missing row (EntitiesQuery removed) is detected" do
      mutated = remove_row(real_text(), "EntitiesQuery")
      assert new_violations(mutated) == [{:missing_row, "EntitiesQuery"}]
    end

    test "a missing row for each of the two rows this REQ added is detected" do
      # The tenant row: exactly the missing-row violation.
      assert violations(remove_row(real_text(), "AttachmentLinksIssue")) ==
               [{:missing_row, "AttachmentLinksIssue"}]

      # The platform row: also reported through the platform-permission set check.
      found = violations(remove_row(real_text(), "PlatformServicesManage"))
      assert {:missing_row, "PlatformServicesManage"} in found
      assert Enum.any?(found, &match?({:platform_set_mismatch, _, _}, &1))
    end

    test "an extra row (a bogus permission appended) is detected" do
      template = row_line(real_text(), "AuditRead")
      bogus = String.replace(template, "AuditRead", "BogusPermissionReq448", global: false)
      mutated = insert_after_header(real_text(), bogus)

      assert new_violations(mutated) == [{:extra_row, "BogusPermissionReq448"}]
    end

    test "a swapped header (two role columns exchanged) is detected" do
      header = row_line(real_text(), "permission")

      swapped =
        header |> String.replace("TENANT_ADMIN TENANT_AUDITOR", "TENANT_AUDITOR TENANT_ADMIN")

      assert swapped != header
      mutated = String.replace(real_text(), header, swapped, global: false)

      assert [{:parse_error, {:header_mismatch, expected, actual}}] = violations(mutated)
      assert expected == ["permission"] ++ role_names() ++ ["scope"]
      assert actual != expected
    end

    test "a duplicate row is detected" do
      dup = row_line(real_text(), "AuditRead")
      mutated = insert_after_header(real_text(), dup)

      assert new_violations(mutated) == [{:parse_error, {:duplicate_row, "AuditRead"}}]
    end

    test "a non-yes/no cell is detected" do
      mutated = replace_token(real_text(), "AuditRead", role_column("CANDIDATE"), "maybe")

      assert new_violations(mutated) == [
               {:parse_error, {:bad_cell, "AuditRead", "CANDIDATE", "maybe"}}
             ]
    end

    test "a non-platform/tenant scope token is detected" do
      mutated = replace_token(real_text(), "AuditRead", scope_column(), "global")
      assert new_violations(mutated) == [{:parse_error, {:bad_scope, "AuditRead", "global"}}]
    end

    test "a short row (one cell dropped) is detected" do
      line = row_line(real_text(), "AuditRead")
      tokens = String.split(line)
      short = tokens |> List.delete_at(3) |> Enum.join(" ")
      mutated = String.replace(real_text(), line, short, global: false)

      assert [{:parse_error, {:bad_row_width, ^short, width}}] = violations(mutated)
      assert width == length(tokens) - 1
    end

    test "a file with no matrix heading or an unterminated fence is a parse error, not a pass" do
      assert violations("# nothing here\n") == [{:parse_error, :no_matrix_block}]

      # The real file cut right after the header line, i.e. with the closing fence missing.
      lines = String.split(real_text(), "\n")
      header_index = Enum.find_index(lines, &String.starts_with?(&1, "permission "))
      unterminated = lines |> Enum.take(header_index + 1) |> Enum.join("\n")
      assert violations(unterminated) == [{:parse_error, :no_matrix_block}]
    end
  end

  # --- code-side sanity (section 6.2 item 4) -----------------------------------------------------

  describe "code-side consistency the matrix relies on" do
    test "PLATFORM_ADMIN outside the platform tenant is denied every core permission" do
      for permission <- Authorization.core_permissions() do
        refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], permission, false),
               inspect(permission)
      end
    end

    test "for every other role the platform flag changes nothing for a granted tenant-scope permission" do
      for role <- Authorization.roles() -- [:PLATFORM_ADMIN],
          permission <- Authorization.core_permissions(),
          Authorization.permission_scope(permission) == :tenant do
        expected = Authorization.role_allows?(role, permission)

        assert Authorization.has_permission_in_scope?([role], permission, true) == expected
        assert Authorization.has_permission_in_scope?([role], permission, false) == expected
      end
    end

    test "no role other than PLATFORM_ADMIN holds a platform-scope permission, flag true or false" do
      for role <- Authorization.roles() -- [:PLATFORM_ADMIN],
          permission <- Authorization.platform_permissions(),
          flag <- [true, false] do
        refute Authorization.has_permission_in_scope?([role], permission, flag),
               "#{role} #{permission} #{flag}"
      end
    end
  end
end
