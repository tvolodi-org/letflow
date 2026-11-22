defmodule Letflow.SecurityProbe.G01RogueRouter do
  @moduledoc """
  G-01 non-vacuity fixture: a deliberately broken router that the G-01 probe
  (`Letflow.SecurityProbe.G01`) must catch, one defect per rule. It is a plain
  `Plug.Router` (it does NOT `use Letflow.Api.AuthorizedRouter`, so it never
  runs `Letflow.Plugs.Authorize`) and it is mounted nowhere: the probe test
  sends its requests straight to it through the same `G01.observe/1` and
  `G01.violations/2` the real-tree test uses. It deliberately exports no
  `__authz_routes__/0`, so the route inventory never discovers it.

  Its route list (`routes/0`) declares every route with `:AuditRead`, so the
  oracle allows some roles and denies the others:

    * `GET /rogue/items` answers 200 to everyone (no authorization) -> M1;
    * `POST /rogue/items` touches a row of tenant B, for every caller -> M2, M5;
    * `GET /rogue/items/:id` answers a foreign tenant's id differently from a
      missing one (an existence oracle) -> M4;
    * `GET /rogue/items/:id/owner` names tenant B's slug in its answer -> M6;
    * `GET /rogue/locked` gives the canonical 403 to every caller -> M3;
    * `GET /rogue/crash` raises -> M7;
    * `PATCH /rogue/definitions/:id` stores the request body (its
      `platform_call` graph) into the company tenant's definition `:id`
      without the platform-tenant check -> M8 (the T-2588 defect).

  The foreign tenant and the company tenant's schema are read from the
  process dictionary (`put_foreign/1`, `put_own/1`), set by the test.
  """

  use Plug.Router

  alias Letflow.Api.Response
  alias Letflow.Repo

  plug(:match)
  plug(:dispatch)

  @key {__MODULE__, :foreign}
  @own_key {__MODULE__, :own}

  @doc "Sets the foreign tenant the rogue routes leak and write (`%{schema, slug, pool}`)."
  def put_foreign(foreign), do: Process.put(@key, foreign)

  @doc "Sets the company tenant whose definitions the rogue write route stores into (`%{schema}`)."
  def put_own(own), do: Process.put(@own_key, own)

  @doc "The rogue routes, in the `G01.routes/0` shape."
  def routes do
    for {method, path} <- [
          {"GET", "/rogue/crash"},
          {"GET", "/rogue/items"},
          {"POST", "/rogue/items"},
          {"GET", "/rogue/items/:id"},
          {"GET", "/rogue/items/:id/owner"},
          {"GET", "/rogue/locked"},
          {"PATCH", "/rogue/definitions/:id"}
        ],
        do: %{method: method, path: path, key: :AuditRead, router: __MODULE__}
  end

  get "/rogue/items" do
    send_resp(conn, 200, ~s({"items":[]}))
  end

  post "/rogue/items" do
    foreign = Process.get(@key)
    {table, _id} = hd(foreign.pool)
    Repo.query!(~s(UPDATE "#{foreign.schema}"."#{table}" SET id = id))
    send_resp(conn, 201, ~s({"ok":true}))
  end

  get "/rogue/items/:id/owner" do
    send_resp(conn, 200, Jason.encode!(%{"owner" => Process.get(@key).slug}))
  end

  get "/rogue/items/:id" do
    foreign_ids = Process.get(@key).pool |> Enum.map(&elem(&1, 1))

    if id in foreign_ids,
      do: send_resp(conn, 404, ~s({"detail":"this record belongs to another tenant"})),
      else: Response.not_found(conn)
  end

  patch "/rogue/definitions/:id" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    schema = Process.get(@own_key).schema

    case Ecto.UUID.dump(id) do
      {:ok, uuid} ->
        Repo.query!(
          ~s(UPDATE "#{schema}".process_definitions SET description = $1 WHERE id = $2),
          [body, uuid]
        )

      :error ->
        :ok
    end

    send_resp(conn, 200, ~s({"ok":true}))
  end

  get "/rogue/locked" do
    Response.forbidden(conn, "insufficient permissions")
  end

  get "/rogue/crash" do
    _ = conn
    raise "G-01 rogue crash"
  end

  match _ do
    Response.not_found(conn)
  end
end
