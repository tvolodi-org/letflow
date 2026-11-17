Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CardPhotosTest do
  @moduledoc """
  T-2041 photos P2, R1–R12, P1–P3, X1–X4 and W1 through the real `Letflow.Router` with real OIDC
  tokens on committed tenants. The service's byte and audit work is exercised at the HTTP surface;
  cross-tenant and wrong-owner probes share the plain 404 (INV-5/INV-10). Sandbox `:auto`.
  """
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Attachments
  alias Letflow.Attachments.{Link, Owners}
  alias Letflow.AttachmentsImageFixture, as: Fx
  alias Letflow.Audit.Entry
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Assets.CardPhotos
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo

  @moduletag :tmp_dir

  @base "/api/v1/modules/assets"
  @admin_a "20412041-2041-4041-8041-204120412041"
  @admin_b "20412041-2042-4041-8041-204120412041"
  @storekeeper "20412041-2043-4041-8041-204120412041"
  @unknown "00000000-0000-4000-8000-000000000000"
  @photo_keys ~w(can_delete caption has_thumbnail id inserted_at is_main locked position)

  defmodule Infected do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(_bytes, _type), do: {:ok, :infected, "TEST-VIRUS"}
  end

  defmodule Down do
    @moduledoc false
    @behaviour Letflow.Repository.AttachmentScanner
    @impl true
    def scan(_bytes, _type), do: raise("scanner down")
  end

  defp setup!(names \\ [:a]) do
    ctx = D.setup!(names)

    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"], sub: @admin_a))
  end

  defp call(method, path, token, body) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, @base <> path)
        body -> Plug.Test.conn(method, @base <> path, body)
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json_call(ctx, method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, @base <> path)
        body -> Plug.Test.conn(method, @base <> path, Jason.encode!(body))
      end

    conn
    |> put_req_header("authorization", "Bearer " <> (token || ctx.tok_a))
    |> put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp json(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp reason(conn, status), do: conn |> json(status) |> Map.fetch!("reason")

  defp file!(tmp, bytes, extension \\ "jpg") do
    path = Path.join(tmp, "p#{System.unique_integer([:positive])}.#{extension}")
    File.write!(path, bytes)

    %Plug.Upload{
      path: path,
      filename: "declared.#{extension}",
      content_type: "application/octet-stream"
    }
  end

  defp upload(ctx, card, tmp, n, extra \\ %{}, token \\ nil) do
    body = Map.merge(%{"original" => file!(tmp, Fx.jpeg(pad: n))}, extra)
    call(:post, "/cards/#{card}/photos", token || ctx.tok_a, body)
  end

  defp upload!(ctx, card, tmp, n, extra \\ %{}) do
    upload(ctx, card, tmp, n, extra) |> json(201)
  end

  defp list(ctx, card, token \\ nil),
    do: json_call(ctx, :get, "/cards/#{card}/photos", nil, token)

  defp list!(ctx, card, token \\ nil), do: list(ctx, card, token) |> json(200)

  defp content(ctx, card, photo, which, token \\ nil),
    do: json_call(ctx, :get, "/cards/#{card}/photos/#{photo}/#{which}", nil, token)

  defp photo_path(card, photo, suffix \\ ""), do: "/cards/#{card}/photos/#{photo}#{suffix}"

  defp attachment_audits(ctx, id) do
    Repo.all(
      from(e in Entry,
        where: e.resource_type == "attachment" and e.resource_id == ^id,
        order_by: e.timestamp
      ),
      prefix: ctx.schema
    )
  end

  defp links(ctx), do: Repo.aggregate(Link, :count, prefix: ctx.schema)

  defp put_scanner!(module) do
    previous = Application.get_env(:letflow, :attachment_scanner)
    Application.put_env(:letflow, :attachment_scanner, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:letflow, :attachment_scanner, previous),
        else: Application.delete_env(:letflow, :attachment_scanner)
    end)
  end

  test "R1 R2 upload strips GPS, serves bytes, audits once and replays", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed

    original = file!(tmp, Fx.jpeg(meta: [:exif]))
    thumbnail = file!(tmp, Fx.png(), "png")

    created =
      upload(ctx, card, tmp, 0, %{
        "original" => original,
        "thumbnail" => thumbnail,
        "caption" => "Front"
      })
      |> json(201)

    assert Enum.sort(Map.keys(created)) == @photo_keys
    assert created["position"] == 1
    assert created["is_main"] == true
    assert created["has_thumbnail"] == true
    assert created["can_delete"] == true
    assert created["caption"] == "Front"
    assert created["locked"] == false

    original_conn = content(ctx, card, created["id"], "original")
    assert original_conn.status == 200
    assert get_resp_header(original_conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(original_conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(original_conn, "content-disposition") == ["inline"]
    assert get_resp_header(original_conn, "cache-control") == ["private, max-age=86400"]
    assert <<0xFF, 0xD8, 0xFF, _::binary>> = original_conn.resp_body
    refute original_conn.resp_body =~ Fx.sentinel()

    thumbnail_conn = content(ctx, card, created["id"], "thumbnail")
    assert thumbnail_conn.status == 200
    assert get_resp_header(thumbnail_conn, "content-type") == ["image/png"]

    stored = Repo.get_by!(Link, [id: created["id"]], prefix: ctx.schema)
    actor = stored.uploaded_by

    assert [%Entry{action: "attachment.added", actor_id: ^actor} = audit] =
             attachment_audits(ctx, created["id"])

    refute inspect(audit) =~ "Front"

    replay =
      upload(ctx, card, tmp, 0, %{
        "original" => file!(tmp, Fx.jpeg(meta: [:exif])),
        "thumbnail" => file!(tmp, Fx.png(), "png"),
        "caption" => "ignored on replay"
      })
      |> json(200)

    assert replay["id"] == created["id"]
    assert length(list!(ctx, card)["photos"]) == 1
    assert length(attachment_audits(ctx, created["id"])) == 1
  end

  test "R3 list reports positions, capabilities and service limits", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    upload!(ctx, card, tmp, 1)
    upload!(ctx, card, tmp, 2)
    body = list!(ctx, card)

    assert Enum.map(body["photos"], & &1["position"]) == [1, 2]
    assert body["can_add"] == true
    assert body["can_delete_any"] == true

    caps = Attachments.limits()
    {:ok, owner} = Owners.fetch("assets_card")

    assert body["limits"] == %{
             "max_photos" => owner.purposes["photo"].max,
             "original_max_bytes" => caps.original.max_bytes,
             "original_max_px" => caps.original.max_px,
             "thumbnail_max_bytes" => caps.thumbnail.max_bytes,
             "thumbnail_max_px" => caps.thumbnail.max_px,
             "caption_max" => caps.caption_max_code_points
           }
  end

  test "R4 malformed uploads are refused without writes", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed

    assert reason(json_call(ctx, :post, "/cards/#{card}/photos", %{}), 422) ==
             "original_required"

    extra = upload(ctx, card, tmp, 1, %{"x" => "no"})
    assert json(extra, 422)["reason"] == "field_not_allowed"
    assert json(extra, 422)["field"] == "x"

    assert reason(upload(ctx, card, tmp, 2, %{"thumbnail" => "text"}), 422) == "field_invalid"

    assert reason(
             upload(ctx, card, tmp, 3, %{"original" => file!(tmp, "GIF89a-not-an-image")}),
             422
           ) == "photo_type_not_allowed"

    assert reason(
             upload(ctx, card, tmp, 4, %{"original" => file!(tmp, <<0xFF, 0xD8, 0xFF>>)}),
             422
           ) == "photo_malformed"

    huge = file!(tmp, :binary.copy(<<0>>, 5_242_881))
    assert reason(upload(ctx, card, tmp, 5, %{"original" => huge}), 422) == "photo_too_large"

    big_thumb = file!(tmp, :binary.copy(<<0>>, 102_401), "png")

    assert reason(upload(ctx, card, tmp, 6, %{"thumbnail" => big_thumb}), 422) ==
             "photo_too_large"

    assert reason(upload(ctx, card, tmp, 7, %{"caption" => String.duplicate("а", 201)}), 422) ==
             "caption_invalid"

    assert links(ctx) == 0

    assert Repo.all(from(e in Entry, where: e.resource_type == "attachment"), prefix: ctx.schema) ==
             []
  end

  @tag timeout: 120_000
  test "R5 the eleventh photo exceeds the owner cap", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    for n <- 1..10, do: upload!(ctx, card, tmp, n)
    assert reason(upload(ctx, card, tmp, 11), 422) == "owner_cap_reached"
    assert length(list!(ctx, card)["photos"]) == 10
  end

  test "R4b a megabyte caption is refused on upload and on PATCH with nothing written", %{
    tmp_dir: tmp
  } do
    ctx = setup!()
    card = ctx.ma.fixed
    big = String.duplicate("a", 1_048_576)

    assert reason(upload(ctx, card, tmp, 1, %{"caption" => big}), 422) == "caption_invalid"
    assert links(ctx) == 0

    photo = upload!(ctx, card, tmp, 2)
    audits_before = length(attachment_audits(ctx, photo["id"]))

    assert reason(json_call(ctx, :patch, photo_path(card, photo["id"]), %{"caption" => big}), 422) ==
             "caption_invalid"

    assert links(ctx) == 1
    assert length(attachment_audits(ctx, photo["id"])) == audits_before
    assert Repo.get_by!(Link, [id: photo["id"]], prefix: ctx.schema).caption == nil
  end

  @tag timeout: 30_000
  test "R4c a 5 MiB fill-byte JPEG is refused fast with nothing written", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    bytes = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 5_242_878)

    attachment_audits = fn ->
      Repo.aggregate(from(e in Entry, where: e.resource_type == "attachment"), :count, :id,
        prefix: ctx.schema
      )
    end

    audits = attachment_audits.()

    task =
      Task.async(fn ->
        call(:post, "/cards/#{card}/photos", ctx.tok_a, %{"original" => file!(tmp, bytes)})
      end)

    assert {:ok, conn} = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
    assert reason(conn, 422) == "photo_malformed"
    assert links(ctx) == 0
    assert attachment_audits.() == audits
  end

  test "R6 the hourly upload rate is enforced before image parse and scan", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    # one real upload → one upload_events row; seed 59 more for the same actor
    first = upload!(ctx, card, tmp, 1)
    link = Repo.get_by!(Link, [id: first["id"]], prefix: ctx.schema)
    now = DateTime.utc_now()

    rows =
      for _ <- 1..59 do
        %{
          id: Ecto.UUID.bingenerate(),
          actor_id: Ecto.UUID.dump!(link.uploaded_by),
          inserted_at: DateTime.add(now, -60, :second)
        }
      end

    Repo.insert_all("upload_events", rows, prefix: ctx.schema)
    assert reason(upload(ctx, card, tmp, 999), 429) == "upload_rate_exceeded"
  end

  test "R7 storage quota refuses the upload and stores nothing", %{tmp_dir: tmp} do
    ctx = setup!()

    Repo.update_all(from(t in Tenant, where: t.id == ^ctx.a.tenant_id),
      set: [storage_allowance_bytes: 100]
    )

    assert reason(upload(ctx, ctx.ma.fixed, tmp, 1), 409) == "storage_quota_exceeded"
    assert links(ctx) == 0
  end

  test "R8 infected and unavailable scanners store nothing", %{tmp_dir: tmp} do
    ctx = setup!()
    put_scanner!(Infected)
    assert reason(upload(ctx, ctx.ma.fixed, tmp, 1), 422) == "photo_infected"
    put_scanner!(Down)
    assert reason(upload(ctx, ctx.ma.fixed, tmp, 2), 503) == "scan_unavailable"
    assert links(ctx) == 0
  end

  test "R9 caption is the only PATCH field and changes are audited", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    photo = upload!(ctx, card, tmp, 1)

    assert json_call(ctx, :patch, photo_path(card, photo["id"]), %{"caption" => "Back"})
           |> json(200)
           |> Map.fetch!("caption") == "Back"

    assert json_call(ctx, :patch, photo_path(card, photo["id"]), %{"caption" => ""})
           |> json(200)
           |> Map.fetch!("caption") == nil

    assert reason(json_call(ctx, :patch, photo_path(card, photo["id"]), %{"caption" => 5}), 422) ==
             "caption_invalid"

    assert reason(
             json_call(ctx, :patch, photo_path(card, photo["id"]), %{"caption" => "a", "x" => 1}),
             422
           ) == "field_not_allowed"

    changed =
      Enum.filter(attachment_audits(ctx, photo["id"]), &(&1.action == "attachment.changed"))

    assert length(changed) == 2
  end

  test "R10 choosing main moves the flag and rejects extra body keys", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    one = upload!(ctx, card, tmp, 1)
    two = upload!(ctx, card, tmp, 2)

    assert json_call(ctx, :post, photo_path(card, two["id"], "/main"), %{})
           |> json(200)
           |> Map.fetch!("is_main") == true

    photos = list!(ctx, card)["photos"]
    assert Enum.find(photos, &(&1["id"] == one["id"]))["is_main"] == false

    assert reason(json_call(ctx, :post, photo_path(card, two["id"], "/main"), %{"x" => 1}), 422) ==
             "field_not_allowed"
  end

  test "R11 order replaces the complete set and bad sets change nothing", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    one = upload!(ctx, card, tmp, 1)
    two = upload!(ctx, card, tmp, 2)
    other = upload!(ctx, ctx.ma.fixed2, tmp, 3)
    path = "/cards/#{card}/photos/order"

    reordered = json_call(ctx, :put, path, %{"photo_ids" => [two["id"], one["id"]]}) |> json(200)
    assert Enum.map(reordered["photos"], & &1["id"]) == [two["id"], one["id"]]

    for ids <- [[one["id"]], [one["id"], one["id"]], [one["id"], other["id"]]] do
      assert reason(json_call(ctx, :put, path, %{"photo_ids" => ids}), 422) == "invalid_order"
      assert Enum.map(list!(ctx, card)["photos"], & &1["id"]) == [two["id"], one["id"]]
    end
  end

  test "R12 delete compacts, promotes main and removes both byte routes", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    one = upload!(ctx, card, tmp, 1, %{"thumbnail" => file!(tmp, Fx.png(), "png")})
    two = upload!(ctx, card, tmp, 2)

    assert json_call(ctx, :delete, photo_path(card, one["id"])).status == 204
    assert [%{"id" => id, "position" => 1, "is_main" => true}] = list!(ctx, card)["photos"]
    assert id == two["id"]
    assert content(ctx, card, one["id"], "original").status == 404
    assert content(ctx, card, one["id"], "thumbnail").status == 404
  end

  test "P1 P3 reader capabilities and write refusals; auditor lacks AssetsRead", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    photo = upload!(ctx, card, tmp, 1)
    storekeeper = S.token(ctx, :a, ["STOREKEEPER"], sub: @storekeeper)

    row = Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.schema)

    row
    |> TenantModule.settings_changeset(%{
      settings: Map.put(row.settings, "storekeeper_grants", ["AssetsRead"])
    })
    |> Repo.update!(prefix: ctx.schema)

    body = list!(ctx, card, storekeeper)
    assert body["can_add"] == false
    assert body["can_delete_any"] == false
    assert Enum.all?(body["photos"], &(&1["can_delete"] == false))
    assert content(ctx, card, photo["id"], "original", storekeeper).status == 200

    for {method, path, payload, expected} <- [
          {:post, "/cards/#{card}/photos", %{}, "photos_add_required"},
          {:patch, photo_path(card, photo["id"]), %{"caption" => "x"}, "photos_add_required"},
          {:post, photo_path(card, photo["id"], "/main"), %{}, "photos_add_required"},
          {:put, "/cards/#{card}/photos/order", %{"photo_ids" => [photo["id"]]},
           "photos_add_required"},
          {:delete, photo_path(card, photo["id"]), nil, "photos_delete_required"}
        ] do
      assert reason(json_call(ctx, method, path, payload, storekeeper), 403) == expected
    end

    assert length(list!(ctx, card)["photos"]) == 1
    auditor = S.token(ctx, :a, ["TENANT_AUDITOR"], sub: Ecto.UUID.generate())
    assert list(ctx, card, auditor).status == 403
    assert json_call(ctx, :post, "/cards/#{card}/photos", %{}, auditor).status == 403
  end

  test "P2 delete_mode covers any, own and none" do
    assert CardPhotos.delete_mode(true, true) == :any
    assert CardPhotos.delete_mode(false, true) == :any
    assert CardPhotos.delete_mode(true, false) == :own
    assert CardPhotos.delete_mode(false, false) == :none

    for permission <- [:PhotosAdd, :PhotosDelete] do
      refute Authorization.role_allows?(:STOREKEEPER, permission)
      refute Authorization.role_allows?(:TENANT_AUDITOR, permission)
    end
  end

  test "X1 X2 X3 X4 cross-tenant, wrong-owner and malformed ids are indistinguishable", %{
    tmp_dir: tmp
  } do
    ctx = setup!([:a, :b])
    ctx = Map.merge(ctx, D.tenant_b!(ctx))
    ctx = Map.put(ctx, :tok_b, S.token(ctx, :b, ["TENANT_ADMIN"], sub: @admin_b))
    photo = upload!(ctx, ctx.ma.fixed, tmp, 1)
    a_card = ctx.ma.fixed
    b_card = ctx.mb.fixed

    routes = [
      {:get, "/cards/#{a_card}/photos", nil},
      {:post, "/cards/#{a_card}/photos", %{}},
      {:get, photo_path(a_card, photo["id"], "/original"), nil},
      {:get, photo_path(a_card, photo["id"], "/thumbnail"), nil},
      {:patch, photo_path(a_card, photo["id"]), %{"caption" => "hijack"}},
      {:post, photo_path(a_card, photo["id"], "/main"), %{}},
      {:put, "/cards/#{a_card}/photos/order", %{"photo_ids" => [photo["id"]]}},
      {:delete, photo_path(a_card, photo["id"]), nil}
    ]

    for {method, path, body} <- routes do
      probe = json_call(ctx, method, path, body, ctx.tok_b) |> json(404)
      unknown_path = String.replace(path, a_card, @unknown)
      unknown = json_call(ctx, method, unknown_path, body, ctx.tok_b) |> json(404)
      assert Map.delete(probe, "trace_id") == Map.delete(unknown, "trace_id")
    end

    for {method, suffix, body} <- [
          {:get, "/original", nil},
          {:get, "/thumbnail", nil},
          {:patch, "", %{"caption" => "hijack"}},
          {:post, "/main", %{}},
          {:delete, "", nil}
        ] do
      probe =
        json_call(ctx, method, photo_path(b_card, photo["id"], suffix), body, ctx.tok_b)
        |> json(404)

      unknown =
        json_call(ctx, method, photo_path(b_card, @unknown, suffix), body, ctx.tok_b) |> json(404)

      assert Map.delete(probe, "trace_id") == Map.delete(unknown, "trace_id")
    end

    for {method, suffix, body} <- [
          {:get, "/original", nil},
          {:patch, "", %{"caption" => "hijack"}},
          {:post, "/main", %{}},
          {:delete, "", nil}
        ] do
      assert json_call(ctx, method, photo_path(ctx.ma.fixed2, photo["id"], suffix), body).status ==
               404
    end

    assert list!(ctx, a_card)["photos"] == [photo]

    assert list(ctx, "x").status == 404
    assert content(ctx, a_card, "x", "original").status == 404
    assert json_call(ctx, :delete, photo_path(a_card, "x")).status == 404
  end

  test "R13 a retired card keeps its gallery readable and editable", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed

    assert D.request(:post, "/cards/#{card}/retire", ctx.tok_a, %{
             "idempotency_key" => Ecto.UUID.generate()
           }).status == 200

    photo = upload!(ctx, card, tmp, 1)
    assert list!(ctx, card)["photos"] == [photo]

    assert json_call(ctx, :patch, photo_path(card, photo["id"]), %{"caption" => "retired"})
           |> json(200)
           |> Map.fetch!("caption") == "retired"
  end

  @tag timeout: 120_000
  test "W1 one administrator walks the whole gallery through HTTP", %{tmp_dir: tmp} do
    ctx = setup!()
    card = ctx.ma.fixed
    one = upload!(ctx, card, tmp, 1)
    two = upload!(ctx, card, tmp, 2, %{"thumbnail" => file!(tmp, Fx.png(), "png")})
    assert length(list!(ctx, card)["photos"]) == 2
    assert content(ctx, card, two["id"], "thumbnail").status == 200

    ordered =
      json_call(ctx, :put, "/cards/#{card}/photos/order", %{"photo_ids" => [two["id"], one["id"]]})
      |> json(200)

    assert Enum.map(ordered["photos"], & &1["id"]) == [two["id"], one["id"]]

    assert json_call(ctx, :post, photo_path(card, two["id"], "/main"), %{})
           |> json(200)
           |> Map.fetch!("is_main")

    assert json_call(ctx, :patch, photo_path(card, one["id"]), %{"caption" => "walked"})
           |> json(200)
           |> Map.fetch!("caption") == "walked"

    assert json_call(ctx, :delete, photo_path(card, two["id"])).status == 204

    assert [%{"id" => id, "position" => 1, "is_main" => true, "caption" => "walked"}] =
             list!(ctx, card)["photos"]

    assert id == one["id"]
  end
end
