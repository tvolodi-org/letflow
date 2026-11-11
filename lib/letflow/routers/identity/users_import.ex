defmodule Letflow.Routers.Identity.UsersImport do
  @moduledoc """
  T-1609 (REQ-791): the two handlers of the xlsx user import, kept out of
  `Letflow.Routers.Identity` so that router does not grow.

  | Route | Handler |
  |---|---|
  | `GET /identity/users/import-template` | `handle_template/1` |
  | `POST /identity/users/import[?dry_run=true]` | `handle_import/2` |

  Both are gated by `:UsersManage` in the router before this module runs. The per-row rules
  are `Letflow.Identity.UserImport`; the file is read by `Letflow.Entities.XlsxImport` (one
  parse, with its zip and size guards).

  The real import is atomic: any refused row means nothing is written and the answer carries
  `"applied" => false`. Otherwise every row is created in one transaction, after the rules
  are checked a second time inside it. `opts` is `user_write_opts/1` of the router plus the
  `:audit_context` (the administrator is the audit actor): the tenant `:prefix` and
  `:tenant_id` come from the authenticated context, never from the request (INV-1).

  T-1731 (REQ-808): with the realm-users flag on (`Letflow.Signup.RealmUsers.configured?/0`), a
  real, applied import also creates the realm login of each created user, after the commit, in
  file order, through `Letflow.Identity.create_sign_in/2` (REQ-807). Every `"created"` result
  entry gets a `"sign_in"` object: `%{"created" => true, "temporary_password" => pw}` or
  `%{"created" => false, "reason" => r}`, `r` one of the fixed atoms of
  `Letflow.Identity.SignIn` as a string, or `"not_attempted"` for the rows after the first
  `provisioner_unavailable`. A failed sign-in never undoes a created user. The answer carries
  `cache-control: no-store` when any password is present. Flag off, dry run and a refused file:
  no `sign_in` key and no provisioner call. Passwords are never logged (INV-4).
  """

  alias Letflow.Api.Response
  alias Letflow.Entities.XlsxImport
  alias Letflow.Entities.XlsxExport
  alias Letflow.Identity
  alias Letflow.Identity.UserImport
  alias Letflow.Repo
  alias Letflow.Routers.Entities.RecordImport

  @row_cap 200
  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @doc false
  def handle_template(conn) do
    case XlsxExport.build(UserImport.fields(), [], %{
           entity_type: "users",
           exported_at: "",
           next_cursor: nil
         }) do
      {:ok, binary} ->
        conn
        |> Plug.Conn.put_resp_content_type(@xlsx_content_type, nil)
        |> Plug.Conn.put_resp_header(
          "content-disposition",
          ~s(attachment; filename="users-template.xlsx")
        )
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
        |> Plug.Conn.send_resp(200, binary)

      {:error, _} ->
        Response.internal_error(conn)
    end
  end

  @doc false
  def handle_import(conn, opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, dry_run?} <- dry_run_param(conn.query_params["dry_run"]),
         {:ok, bytes} <- xlsx_bytes(conn),
         {:ok, rows} <-
           XlsxImport.convert_detailed(bytes, UserImport.fields(),
             upsert: false,
             max_rows: @row_cap,
             required_headers: UserImport.columns()
           ) do
      run(conn, rows, prefix, opts, dry_run?)
    else
      error -> refuse(conn, error)
    end
  end

  defp run(conn, rows, prefix, _opts, true) do
    Response.ok(conn, %{"results" => UserImport.check(rows, prefix), "dry_run" => true})
  end

  defp run(conn, rows, prefix, opts, false) do
    results = UserImport.check(rows, prefix)

    if UserImport.all_ok?(results) do
      write(conn, rows, prefix, opts)
    else
      Response.ok(conn, %{"results" => results, "applied" => false})
    end
  end

  # One transaction: the rules are checked again inside it (closes the window between the
  # first check and the write), then every row goes through Identity.create_user/2. Any
  # failure rolls the whole file back.
  defp write(conn, rows, prefix, opts) do
    outcome =
      Repo.transaction(fn ->
        results = UserImport.check(rows, prefix)

        if UserImport.all_ok?(results) do
          rows
          |> UserImport.to_create(results)
          |> Enum.map(fn attrs -> create!(rows, results, attrs, opts) end)
          |> then(&{:applied, results, &1})
        else
          Repo.rollback({:refused, results})
        end
      end)

    case outcome do
      {:ok, {:applied, results, users}} ->
        answer_applied(conn, results, users, opts)

      {:error, {:refused, results}} ->
        Response.ok(conn, %{"results" => results, "applied" => false})

      {:error, {:row_failed, username}} ->
        results = failed_results(rows, prefix, username)
        Response.ok(conn, %{"results" => results, "applied" => false})
    end
  rescue
    _ -> Response.internal_error(conn)
  end

  defp create!(_rows, _results, attrs, opts) do
    case Identity.create_user(attrs, opts) do
      {:ok, user} -> user
      {:error, _reason} -> Repo.rollback({:row_failed, attrs["username"]})
    end
  end

  # REQ-808: after the commit, with the realm-users flag on, create the realm login of every
  # created user (file order, sequentially). A failed sign-in never undoes a created user. After
  # the first `provisioner_unavailable` the remaining rows are `not_attempted`. Flag off: the
  # answer is exactly the one without a `sign_in` key and the provisioner is never called.
  defp answer_applied(conn, results, users, opts) do
    if Letflow.Signup.RealmUsers.configured?() do
      {sign_ins, _outage?} =
        Enum.map_reduce(users, false, fn user, outage? -> sign_in_entry(user, outage?, opts) end)

      conn =
        if Enum.any?(sign_ins, &(&1["created"] == true)),
          do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store"),
          else: conn

      Response.ok(conn, %{
        "results" => merge_sign_ins(results, sign_ins),
        "applied" => true
      })
    else
      Response.ok(conn, %{"results" => results, "applied" => true})
    end
  end

  defp sign_in_entry(_user, true, _opts),
    do: {%{"created" => false, "reason" => "not_attempted"}, true}

  defp sign_in_entry(user, false, opts) do
    case safe_create_sign_in(user.id, opts) do
      {:ok, _bound, password} ->
        {%{"created" => true, "temporary_password" => password}, false}

      {:error, reason} ->
        {%{"created" => false, "reason" => Atom.to_string(reason)},
         reason == :provisioner_unavailable}
    end
  end

  # Only a fixed reason atom leaves this function, never an exception (INV-4).
  defp safe_create_sign_in(user_id, opts) do
    case Identity.create_sign_in(user_id, opts) do
      {:ok, _bound, _password} = ok -> ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :bind_failed}
    end
  rescue
    _ -> {:error, :bind_failed}
  end

  defp merge_sign_ins(results, sign_ins) do
    {merged, _rest} =
      Enum.map_reduce(results, sign_ins, fn
        %{"outcome" => "created"} = entry, [sign_in | rest] ->
          {Map.put(entry, "sign_in", sign_in), rest}

        entry, rest ->
          {entry, rest}
      end)

    merged
  end

  # After the rollback: the report as the checks see it now, with the row that failed marked
  # `internal_error`. A retry then shows that row as `unchanged` or `user_exists_different`.
  defp failed_results(rows, prefix, username) do
    rows
    |> UserImport.check(prefix)
    |> Enum.zip(rows)
    |> Enum.map(fn {result, row} ->
      if row_username(row) == username and result["status"] == "ok" do
        %{
          "line" => result["line"],
          "status" => "error",
          "reason" => %{"type" => "internal_error"}
        }
      else
        result
      end
    end)
  end

  defp row_username(%{result: {:ok, %{"field_values" => values}}}),
    do: values |> Map.get("username", "") |> to_string() |> String.trim()

  defp row_username(_row), do: nil

  # ── request ───────────────────────────────────────────────────────────

  defp dry_run_param(nil), do: {:ok, false}
  defp dry_run_param("true"), do: {:ok, true}
  defp dry_run_param("false"), do: {:ok, false}
  defp dry_run_param(_other), do: {:error, :invalid_dry_run}

  defp xlsx_bytes(%{body_params: %{"_xlsx" => bytes}}) when is_binary(bytes), do: {:ok, bytes}
  defp xlsx_bytes(_conn), do: {:error, :xlsx_unreadable}

  # ── answers ───────────────────────────────────────────────────────────

  defp refuse(conn, {:error, :invalid_dry_run}),
    do: Response.unprocessable(conn, "dry_run must be true or false")

  defp refuse(conn, {:error, :xlsx_missing_header, %{headers: headers}}) do
    Response.unprocessable_with(conn, "xlsx file is missing a required column", %{
      "code" => "xlsx_missing_header",
      "headers" => headers
    })
  end

  defp refuse(conn, {:error, :too_many_records, _count}) do
    Response.payload_too_large(
      conn,
      "import batch exceeds the #{@row_cap}-row cap"
    )
  end

  defp refuse(conn, error), do: RecordImport.refuse_xlsx(conn, error)
end
