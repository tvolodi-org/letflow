defmodule Letflow.Routers.Identity.UsersImport do
  @moduledoc """
  T-1609 (REQ-790): the two handlers of the xlsx user import, kept out of
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
          |> Enum.each(fn attrs -> create!(rows, results, attrs, opts) end)

          {:applied, results}
        else
          Repo.rollback({:refused, results})
        end
      end)

    case outcome do
      {:ok, {:applied, results}} ->
        Response.ok(conn, %{"results" => results, "applied" => true})

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
      {:ok, _user} -> :ok
      {:error, _reason} -> Repo.rollback({:row_failed, attrs["username"]})
    end
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
