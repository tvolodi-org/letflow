defmodule Mix.Tasks.Letflow.CheckRoleScopeGrantsWriters do
  @shortdoc "Fails when code outside the allowlist writes the role-grants table"

  @moduledoc """
  Static single-writer scan for the org-scoped role grants table (REQ-517 / GH #2535 PR 2a,
  decision 0051 D1; design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  section 3.13; SEC rule #2612: wired into `mix letflow.check`).

  Only the allowlisted files below may write the table:

    * `lib/letflow/identity/role_scope_grants.ex`
    * `lib/letflow/identity/role_scope_grants/backfill.ex`
    * `lib/letflow/identity/role_scope_grant.ex`
    * `lib/mix/tasks/letflow.check_role_scope_grants_writers.ex` (this file names the patterns)

  ## Roots and rules

  Scans every `.ex` file under `lib` and every regular file under `priv/modules` (a missing
  root is skipped); NOT `test/`, NOT `priv/repo/migrations/`. The schema name is the WHOLE
  WORD of the schema module, and the table name the whole word of the table (word characters
  include `_`, so index and constraint names that merely start with the table name do not
  match, and the plural context module name never matches the singular schema word, so a
  call into the context module is by construction the legal way to write). A line is a
  violation when it matches:

    * `:repo_write` -- a `Repo.insert`, `insert!`, `insert_all`, `update`, `update!`,
      `update_all`, `delete`, `delete!` or `delete_all` call whose text on the same line and
      the next two lines contains the schema or table name;
    * `:multi_write` -- an `Ecto.Multi` `insert`, `update`, `delete`, `insert_all`,
      `update_all` or `delete_all` call with the same window rule;
    * `:raw_sql` -- `INSERT INTO`, `UPDATE` or `DELETE FROM` followed by an optional schema
      qualifier and the table name (case-insensitive, one line);
    * `:struct_literal` -- a struct literal of the schema, or a call of its `changeset(`.

  Lines whose trimmed text starts with `#` are skipped; doc text inside heredocs is NOT
  skipped (prose in a non-allowlisted file avoids the exact words; a violation there is
  reworded, never allowlisted). Reads (`from(g in <schema>)` with `Repo.all/one/exists?`),
  the manifest entry and doc mentions are allowed.

  ## Known limit

  Line-oriented and textual: a schema aliased into a variable or a name split across a
  string concatenation is not caught. REVIEWER covers that case.

  ## Usage

      mix letflow.check_role_scope_grants_writers

  `Mix.raise/1` listing every violation (`path:line [rule] text`) when any is found.
  """

  use Mix.Task

  @default_roots ["lib", "priv/modules"]

  @allowlist [
    "lib/letflow/identity/role_scope_grants.ex",
    "lib/letflow/identity/role_scope_grants/backfill.ex",
    "lib/letflow/identity/role_scope_grant.ex",
    "lib/mix/tasks/letflow.check_role_scope_grants_writers.ex"
  ]

  @name ~S"(?:\bRoleScopeGrant\b|\brole_scope_grants\b)"
  @repo_call ~S"Repo\.(?:insert_all|insert!|insert|update_all|update!|update|delete_all|delete!|delete)\b"
  @multi_call ~S"(?:Multi\.|\|>\s*Ecto\.Multi\.|\|>\s*Multi\.)(?:insert_all|insert|update_all|update|delete_all|delete)\b"
  @raw_sql_regex Regex.compile!(
                   ~S{(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:"[^"]*"\.|[A-Za-z0-9_]+\.)?"?role_scope_grants\b},
                   "i"
                 )
  @name_regex Regex.compile!(@name)
  @repo_regex Regex.compile!(@repo_call)
  @multi_regex Regex.compile!(@multi_call)
  @struct_regex ~r/%(?:[A-Za-z0-9_.]*\.)?RoleScopeGrant\{|\bRoleScopeGrant\.changeset\(/

  @type rule :: :repo_write | :multi_write | :raw_sql | :struct_literal
  @type violation :: %{path: String.t(), line: pos_integer(), rule: rule(), text: String.t()}

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    case scan(@default_roots) do
      [] ->
        Mix.shell().info("role_scope_grants writer scan: no violations")
        :ok

      violations ->
        listing =
          Enum.map_join(violations, "\n", fn v ->
            "  #{v.path}:#{v.line} [#{v.rule}] #{v.text}"
          end)

        Mix.raise(
          "role_scope_grants writer scan: #{length(violations)} violation(s); only " <>
            "Letflow.Identity.RoleScopeGrants may write the table:\n" <> listing
        )
    end
  end

  @doc "The allowlisted paths (relative to the project root, forward slashes)."
  @spec allowlist() :: [String.t()]
  def allowlist, do: @allowlist

  @doc "Scans every file under `roots` (missing roots are skipped), skipping the allowlist."
  @spec scan(roots :: [Path.t()]) :: [violation()]
  def scan(roots) when is_list(roots) do
    roots
    |> Enum.flat_map(&files_under/1)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 in @allowlist))
    |> Enum.sort()
    |> Enum.flat_map(fn path -> audit(File.read!(path), path) end)
  end

  @doc "The violations in one file's `content`, reported against `path`."
  @spec audit(content :: String.t(), path :: String.t()) :: [violation()]
  def audit(content, path) when is_binary(content) and is_binary(path) do
    lines = content |> String.split("\n") |> Enum.with_index(1)
    texts = Enum.map(lines, &elem(&1, 0))

    for {text, line} <- lines,
        not comment?(text),
        rule <- rules_for(text, window(texts, line)),
        do: %{path: path, line: line, rule: rule, text: String.trim(text)}
  end

  # The line and the next two lines.
  defp window(texts, line), do: texts |> Enum.slice(line - 1, 3) |> Enum.join("\n")

  defp comment?(text), do: text |> String.trim_leading() |> String.starts_with?("#")

  defp rules_for(text, window) do
    [
      {:repo_write, Regex.match?(@repo_regex, text) and Regex.match?(@name_regex, window)},
      {:multi_write, Regex.match?(@multi_regex, text) and Regex.match?(@name_regex, window)},
      {:raw_sql, Regex.match?(@raw_sql_regex, text)},
      {:struct_literal, Regex.match?(@struct_regex, text)}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp normalize(path), do: String.replace(path, "\\", "/")

  defp files_under(root) do
    if File.dir?(root) do
      pattern = if root == "lib", do: "**/*.ex", else: "**"

      root
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end
end
