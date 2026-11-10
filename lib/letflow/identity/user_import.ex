defmodule Letflow.Identity.UserImport do
  @moduledoc """
  T-1609 (REQ-790): the per-row rules of the tenant administrator's xlsx user import.

  The file carries three columns, `username`, `display_name` and `email`, and nothing else:
  no password, role or group column, so the file cannot be used to grant privilege. Users
  are created through `Letflow.Identity.create_user/2` (login directory and `user.create`
  audit entry included), so an imported user is exactly what the single-create form makes.

  `check/2` is the one place the rules live; the dry run and the real run both call it, and
  the real run calls it again inside its transaction. Each row gets one result in the
  `ImportResultRow` shape of the web import screens:

      %{"line" => 3, "status" => "ok", "outcome" => "created" | "unchanged"}
      %{"line" => 3, "status" => "error", "reason" => %{"type" => ..., "header" => ...}}

  The first refusal of a row wins. A reason names a header, never the cell text.

  **No update path.** An import never changes an existing user. A username that exists with
  the same display name and e-mail is `unchanged` (so the whole corrected file can be
  uploaded again); a username that exists with other data is refused
  (`user_exists_different`).

  Tenant scoping (INV-1): the one read takes the caller's tenant `:prefix`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.User
  alias Letflow.Repo

  @columns ["username", "display_name", "email"]
  @max_len 255
  @email_re ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/

  @doc "The header row of the template and the only columns the import accepts."
  @spec columns() :: [String.t()]
  def columns, do: @columns

  @doc "Field declarations for `Letflow.Entities.XlsxImport.convert_detailed/3`."
  @spec fields() :: [map()]
  def fields, do: Enum.map(@columns, &%{"name" => &1, "type" => "string"})

  @doc """
  One result per converted row (`XlsxImport` entries: `%{line:, result:}`), in file order.
  `prefix` is the caller's tenant schema.
  """
  @spec check([map()], String.t()) :: [map()]
  def check(rows, prefix) when is_list(rows) and is_binary(prefix) do
    stage1 = Enum.map(rows, &static_check/1)
    existing = existing_users(stage1, prefix)

    {results, _seen} =
      Enum.map_reduce(stage1, %{usernames: MapSet.new(), emails: MapSet.new()}, fn
        {:refused, line, reason}, seen ->
          {refused(line, reason), seen}

        {:ok, line, attrs}, seen ->
          uname = String.downcase(attrs["username"])
          email = String.downcase(attrs["email"])

          cond do
            MapSet.member?(seen.usernames, uname) ->
              {refused(line, {"user_duplicate_in_file", "username"}), seen}

            MapSet.member?(seen.emails, email) ->
              {refused(line, {"user_duplicate_in_file", "email"}), seen}

            true ->
              seen = %{
                usernames: MapSet.put(seen.usernames, uname),
                emails: MapSet.put(seen.emails, email)
              }

              {existing_or_new(line, attrs, existing), seen}
          end
      end)

    results
  end

  @doc "True when no row is refused."
  @spec all_ok?([map()]) :: boolean()
  def all_ok?(results), do: Enum.all?(results, &(&1["status"] == "ok"))

  @doc "The attribute maps of the rows that would be created, in file order."
  @spec to_create([map()], [map()]) :: [map()]
  def to_create(rows, results) do
    rows
    |> Enum.zip(results)
    |> Enum.flat_map(fn
      {%{result: {:ok, %{"field_values" => values}}}, %{"outcome" => "created"}} ->
        [normalise(values)]

      _other ->
        []
    end)
  end

  # ── rules ─────────────────────────────────────────────────────────────

  defp static_check(%{line: line, result: {:ok, %{"field_values" => values}}}) do
    attrs = normalise(values)

    cond do
      header = Enum.find(@columns, &(Map.get(attrs, &1) == "")) ->
        {:refused, line, {"user_field_required", header}}

      header = Enum.find(@columns, &(String.length(Map.fetch!(attrs, &1)) > @max_len)) ->
        {:refused, line, {"user_field_invalid", header}}

      not Regex.match?(@email_re, attrs["email"]) ->
        {:refused, line, {"user_field_invalid", "email"}}

      true ->
        case invalid_header(attrs) do
          nil -> {:ok, line, attrs}
          header -> {:refused, line, {"user_field_invalid", header}}
        end
    end
  end

  defp static_check(%{line: line, result: {:error, reason, header}}),
    do: {:refused, line, {Atom.to_string(reason), header}}

  defp static_check(%{line: line}), do: {:refused, line, {"user_field_invalid", nil}}

  # The changeset is the single source of the field rules.
  defp invalid_header(attrs) do
    changeset = User.create_changeset(%User{}, attrs)

    if changeset.valid? do
      nil
    else
      Enum.find_value(changeset.errors, fn {field, _} ->
        name = Atom.to_string(field)
        if name in @columns, do: name
      end) || "username"
    end
  end

  defp normalise(values) do
    Map.new(@columns, fn column ->
      {column, values |> Map.get(column, "") |> to_string() |> String.trim()}
    end)
  end

  defp existing_users(stage1, prefix) do
    names = for {:ok, _line, attrs} <- stage1, do: attrs["username"]

    if names == [] do
      %{}
    else
      from(u in User,
        where: u.username in type(^names, {:array, :string}),
        select: {u.username, {u.display_name, u.email}}
      )
      |> Repo.all(prefix: prefix)
      |> Map.new()
    end
  end

  defp existing_or_new(line, attrs, existing) do
    case Map.fetch(existing, attrs["username"]) do
      {:ok, {display_name, email}} ->
        if display_name == attrs["display_name"] and email == attrs["email"] do
          %{"line" => line, "status" => "ok", "outcome" => "unchanged"}
        else
          refused(line, {"user_exists_different", "username"})
        end

      :error ->
        %{"line" => line, "status" => "ok", "outcome" => "created"}
    end
  end

  defp refused(line, {type, header}) do
    reason = if header, do: %{"type" => type, "header" => header}, else: %{"type" => type}
    %{"line" => line, "status" => "error", "reason" => reason}
  end
end
