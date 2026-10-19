defmodule Letflow.GH2747CursorTailContextTest do
  @moduledoc """
  GH #2747, context level: every keyset list function returns `{:error, :invalid_cursor}`
  (never raises) for a cursor with a valid prefix and mint slot but a malformed tail. Spec:
  `test/specs/GH-2747.md`.

  Covers the decoders that no route reaches (`Repository.list_versions/4`,
  `Repository.Activation.list_history/4`), those whose route fixture is costly
  (`Attachments.list/2`, `EntityAttachments.list/2`), and pins the exact error atom for the
  identity, definitions and service-catalog listings that the HTTP file
  (`test/letflow/routers/gh2747_cursor_tail_http_test.exs`) pins by status. Real Postgres via
  `TenantFixture`; no mocks.
  """

  use Letflow.DataCase, async: false

  import Letflow.TestSupport.CursorForgery, only: [forgeries: 2, valid: 2]

  alias Letflow.Api.Pagination
  alias Letflow.Definitions
  alias Letflow.Identity
  alias Letflow.Repository
  alias Letflow.Repository.Activation
  alias Letflow.Repository.Attachments
  alias Letflow.Repository.EntityAttachments
  alias Letflow.ServiceCatalog
  alias Letflow.TenantFixture

  # name, cursor prefix, slot layout. The first slot is the mint time.
  @cases [
    {:repository_list_versions, "RV:", [:mint, :uuid, :int]},
    {:activation_list_history, "AH:", [:mint, :uuid, :dt]},
    {:activation_list_history_for_artifact, "AH:", [:mint, :uuid, :dt]},
    {:attachments_list, "IA:", [:mint_dt, :uuid]},
    {:entity_attachments_list, "ERA:", [:mint_dt, :uuid]},
    {:identity_list_users, "U:", [:mint, :dt, :uuid]},
    {:identity_list_tenants, "T:", [:mint, :dt, :uuid]},
    {:identity_list_group_members, "G:", [:mint, :dt, :uuid]},
    {:definitions_list_paginated, "DL:", [:mint, :uuid, :dt]},
    {:definitions_search_paginated, "DS:", [:mint, :rank_id, :dt]},
    {:service_catalog_list_for_tenant, "SC:", [:mint_dt, :string]},
    {:service_catalog_list_all, "SCA:", [:mint_dt, :string]}
  ]

  @page_size 5

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2747-ctx")
    {:ok, group} = Identity.create_group(%{"name" => "gh2747-ctx-g"}, prefix: tenant.schema_name)
    %{tenant: tenant, group_id: group.id}
  end

  # The functions taking a decoded `%Pagination.Cursor{}` (the router decodes the prefix and
  # expiry first). A cursor that does not even decode is the caller's `:invalid_cursor`.
  defp decoded(encoded, prefix) do
    case Pagination.decode_cursor(encoded, prefix, byte_size(prefix)) do
      {:ok, cursor} -> {:ok, cursor}
      {:error, _reason} -> {:error, :invalid_cursor}
    end
  end

  defp run(:repository_list_versions, cursor, ctx),
    do:
      Repository.list_versions(:definition, "gh2747", ctx.tenant.schema_name,
        cursor: cursor,
        page_size: @page_size
      )

  defp run(:activation_list_history, cursor, ctx),
    do:
      Activation.list_history(nil, nil, ctx.tenant.schema_name,
        cursor: cursor,
        page_size: @page_size
      )

  defp run(:activation_list_history_for_artifact, cursor, ctx),
    do:
      Activation.list_history(:definition, "gh2747", ctx.tenant.schema_name,
        cursor: cursor,
        page_size: @page_size
      )

  defp run(:attachments_list, cursor, ctx),
    do:
      Attachments.list(
        %{instance_id: Ecto.UUID.generate(), cursor: cursor, page_size: @page_size},
        prefix: ctx.tenant.schema_name
      )

  defp run(:entity_attachments_list, cursor, ctx),
    do:
      EntityAttachments.list(
        %{
          entity_type: "gh2747_ent",
          record_id: Ecto.UUID.generate(),
          cursor: cursor,
          page_size: @page_size
        },
        prefix: ctx.tenant.schema_name
      )

  defp run(:identity_list_users, cursor, ctx) do
    with {:ok, struct} <- decoded(cursor, "U:"),
         do:
           Identity.list_users(%{cursor: struct, page_size: @page_size},
             prefix: ctx.tenant.schema_name
           )
  end

  defp run(:identity_list_tenants, cursor, _ctx) do
    with {:ok, struct} <- decoded(cursor, "T:"),
         do: Identity.list_tenants(%{cursor: struct, page_size: @page_size})
  end

  defp run(:identity_list_group_members, cursor, ctx) do
    with {:ok, struct} <- decoded(cursor, "G:"),
         do:
           Identity.list_group_members(
             ctx.group_id,
             %{cursor: struct, page_size: @page_size},
             prefix: ctx.tenant.schema_name
           )
  end

  defp run(:definitions_list_paginated, cursor, ctx),
    do:
      Definitions.list_paginated(%{cursor: cursor, page_size: @page_size},
        prefix: ctx.tenant.schema_name
      )

  defp run(:definitions_search_paginated, cursor, ctx),
    do:
      Definitions.search_paginated("gh2747", %{cursor: cursor, page_size: @page_size},
        prefix: ctx.tenant.schema_name
      )

  defp run(:service_catalog_list_for_tenant, cursor, ctx),
    do:
      ServiceCatalog.list_for_tenant(
        %{cursor: cursor, page_size: @page_size},
        ctx.tenant.tenant_id
      )

  defp run(:service_catalog_list_all, cursor, _ctx),
    do: ServiceCatalog.list_all(%{cursor: cursor, page_size: @page_size})

  for {name, prefix, layout} <- @cases do
    test "#{name}: a valid prefix + mint with a malformed tail is {:error, :invalid_cursor}",
         ctx do
      name = unquote(name)
      prefix = unquote(prefix)
      layout = unquote(layout)

      # Positive control: the all-valid forging is accepted, so each refusal below is down to
      # the one mangled slot.
      assert {name, :valid_cursor, elem(run(name, valid(prefix, layout), ctx), 0)} ==
               {name, :valid_cursor, :ok}

      for {label, cursor, bad_mint?} <- forgeries(prefix, layout) do
        result = run(name, cursor, ctx)

        if bad_mint? do
          # A bad MINT is refused by decode_cursor/4 before the seek decoder runs: the
          # reason may be :invalid_cursor or :expired, but it is always an error tuple.
          assert {label, match?({:error, _reason}, result)} == {label, true}
        else
          assert {label, result} == {label, {:error, :invalid_cursor}}
        end
      end
    end
  end
end
