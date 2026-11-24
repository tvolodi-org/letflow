defmodule Letflow.OutboundDestinations do
  @moduledoc """
  The per-tenant OUTBOUND ALLOW-LIST (T-2597, pilot gap G14 -- the "Register a
  tenant" pilot; decision record G2 (c), the "deny by default" option).

  ## What it is

  A tenant's DEFINITIONS may reach OUTSIDE the tenant only where its own list
  says so (the exceptions are listed below). The list
  has two kinds of entry:

    * a CHANNEL -- the mail channel (`email`), the file channel (`file`), the
      HTTP channel (`http`). The door.
    * a DESTINATION on a channel -- a recipient domain for the mail channel
      (`uat.letflow.internal`), a host for the HTTP channel. The address
      behind the door.

  A new tenant's list is EMPTY, so it may reach nothing outside: the platform's
  own notifications to a tenant's own users (the `Letflow.Notifications`
  per-user path) are NOT outbound and are not governed here.

  ## Who may change it

  Only the holder of `:OutboundDestinationsManage` -- `TENANT_ADMIN` and
  `PLATFORM_ADMIN`, never `PROCESS_DESIGNER` (decision record G2 (c): "the
  person who draws the process is not the person who opens the door"). Every
  change is an audit row with the actor.

  ## Where it is checked

  Twice, because the list can shrink after a version was switched on:

    * at ACTIVATION (`Letflow.Definitions.check_outbound_destinations/2`) -- a
      step whose channel or destination is not on the list is refused, so a
      version that cannot send anything is never switched on. The fence runs
      on EVERY path that switches a version on: activate, reactivate, version
      rollback and promotion apply (a promoted graph is the TARGET tenant's
      graph, so the TARGET tenant's list decides what it may reach);
    * at DISPATCH -- the list is read again, so a destination that was removed
      after the activation stops the step that would have used it (decision
      record G2 S7). A notification step is re-read by
      `Letflow.NotificationSteps.Dispatcher`, an inline HTTP step by
      `Letflow.Engine.ServiceTaskDispatcher` (`dispatch_inline/4`).

  The check is FAIL-CLOSED: a list that cannot be read is a list that allows
  nothing, and a destination that cannot be READ (a placeholder host) is a
  destination that is not allowed.

  ## The extension point (owner decision D-180, not built here)

  The list is a tenant's own data, not a definition's: a tenant that later
  forks a standard definition (`custom`, `based_on: <standard key>@<version>`)
  brings its own list with it, and the binding that says which definition runs
  changes nothing here. Nothing in this module assumes that a definition is
  editable by whoever sees it, nor that a tenant has exactly one definition per
  key.

  ## Pure and total

  `check/3` never raises and never logs the value it was given (INV-4): a
  destination is a domain or a host, not an address of a person.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Definitions.Graph
  alias Letflow.OutboundDestinations.Entry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  # The channels the list may name. A chat channel ("telegram") is NOT here:
  # the record says the list is designed so a channel is one more value, and
  # the Telegram adapter is a later task (the record's (c) recommendation).
  @channels ~w(email file http)

  # The byte cap of ONE destination (a domain or a host). The DNS limit is 253
  # octets; the cap is checked BEFORE any per-character work (SF-01).
  @max_destination_bytes 253

  # The byte cap of the URL template of an inline HTTP step, before it is
  # parsed for its host (SF-01).
  @max_url_bytes 2048

  # The byte cap of a channel name, checked before it is lower-cased (SF-01).
  # An over-cap value names no channel: it is refused, never lower-cased.
  @max_channel_bytes 16

  @type channel :: String.t()
  # `:unknown_host` is a destination that CANNOT be checked (a placeholder
  # host): the check refuses it, exactly as it refuses an unreadable one.
  @type destination :: String.t() | nil | :unknown_host

  @type error ::
          :invalid_channel
          | :invalid_destination
          | :not_found
          | :channel_not_allowed
          | :destination_not_allowed
          | :allow_list_unavailable

  @doc """
  The channels a tenant's list may name.
  """
  @spec channels() :: [channel()]
  def channels, do: @channels

  @doc """
  Every entry of the tenant's list: the channel rows (no destination) and the
  destination rows, ordered by channel and destination.

  The tenant is DERIVED from the prefix the list lives in, never taken from
  the caller (INV-1 (c)): a caller-supplied tenant id can disagree with the
  schema the row is written into, and a row that disagrees is a row of no
  known tenant.
  """
  @spec list(String.t()) :: {:ok, [Entry.t()]} | {:error, error()}
  def list(prefix) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      entries =
        from(e in Entry,
          where: e.tenant_id == ^tenant_id,
          order_by: [asc: e.channel, asc: e.destination]
        )
        |> Repo.all(prefix: prefix)

      {:ok, entries}
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_schema_name}
    end
  rescue
    # A tenant not yet migrated (no table): a typed error, not a raw 500.
    _e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :allow_list_unavailable}
  end

  @doc """
  Adds one entry to the tenant's list: the channel itself (`destination` is
  `nil`) or one destination on that channel.

  The actor is stored with the row and written to the audit log. Adding an
  entry that is already there is not an error: the row is returned unchanged
  (the list is a set, not a log).

  The tenant is DERIVED from the prefix, exactly as in `list/1` and
  `check/3` (INV-1 (c)).
  """
  @spec add(String.t(), String.t() | nil, term(), term()) ::
          {:ok, Entry.t()} | {:error, error()}
  def add(prefix, actor_id, channel, destination) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, n_channel} <- normalize_channel(channel),
         {:ok, n_dest} <- normalize_destination(n_channel, destination) do
      now = DateTime.utc_now()

      row = %Entry{
        tenant_id: tenant_id,
        channel: n_channel,
        destination: n_dest,
        inserted_by: actor_id,
        inserted_at: now
      }

      multi =
        Multi.new()
        # A plain insert: the unique indexes make a second row of the same
        # entry impossible, and the violation rolls the whole Multi back (so a
        # repeated add writes no audit row -- there was no change).
        |> Multi.insert(:entry, row, prefix: prefix)
        |> Audit.append_multi(
          :audit,
          %{
            actor_id: actor_id,
            action: "outbound_destinations.add",
            resource_type: "outbound_destination",
            resource_id: resource_id(n_channel, n_dest),
            before_state: nil,
            after_state: %{"channel" => n_channel, "destination" => n_dest}
          },
          prefix
        )

      case Repo.transaction(multi) do
        {:ok, %{entry: entry}} ->
          {:ok, entry}

        {:error, _step, reason, _changes} ->
          # A unique violation means the entry is already on the list: the
          # list is a set, so the existing row is the answer.
          case existing(prefix, tenant_id, n_channel, n_dest) do
            nil -> {:error, reason}
            found -> {:ok, found}
          end
      end
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_schema_name}
      {:error, :invalid_channel} -> {:error, :invalid_channel}
      {:error, :invalid_destination} -> {:error, :invalid_destination}
    end
  rescue
    # A concurrent writer won the unique index of the entry (INV-8): the list
    # is a set, so the row that is already there is the answer.
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Postgrex.Error{postgres: %{code: :unique_violation}}, e) or
           is_struct(e, Ecto.ConstraintError) do
        # The arguments are the raw ones here (a `with` binding is not in
        # scope in the function-level rescue): normalise again for the lookup.
        with {:ok, n_channel} <- normalize_channel(channel),
             {:ok, n_dest} <- normalize_destination(n_channel, destination),
             %Entry{} = found <- existing_for_prefix(prefix, n_channel, n_dest) do
          {:ok, found}
        else
          _ -> {:error, :conflict}
        end
      else
        # Any other database error (a tenant not yet migrated: no table): a
        # typed error, not a raw 500 (INV-8).
        {:error, :allow_list_unavailable}
      end

    _e in DBConnection.ConnectionError ->
      {:error, :allow_list_unavailable}
  end

  @doc """
  Removes one entry from the tenant's list: the channel itself (and, with it,
  the destinations of that channel) or one destination.

  `:removed` when something was removed, `:absent` when the entry was not on
  the list (removing what is not there is not an error).

  The tenant is DERIVED from the prefix, exactly as in `list/1` and `add/4`
  (INV-1 (c)).
  """
  @spec remove(String.t(), String.t() | nil, term(), term()) ::
          {:ok, :removed | :absent} | {:error, error()}
  def remove(prefix, actor_id, channel, destination) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, channel} <- normalize_channel(channel),
         {:ok, destination} <- normalize_destination(channel, destination) do
      multi =
        Multi.new()
        |> Multi.run(:existing, fn _repo, _changes ->
          {:ok, existing(prefix, tenant_id, channel, destination)}
        end)
        |> Multi.run(:deleted, fn _repo, %{existing: existing} ->
          case existing do
            nil ->
              {:ok, 0}

            row ->
              {count, _rows} =
                from(e in Entry, where: e.id == ^row.id)
                |> Repo.delete_all(prefix: prefix)

              {:ok, count}
          end
        end)
        |> Multi.run(:siblings, fn _repo, %{deleted: count} ->
          # Removing the CHANNEL removes the destinations behind it too: a
          # destination of a channel that is not allowed is inert, and leaving
          # it on the list would show an exposure that is not there.
          if is_nil(destination) and count > 0 do
            {count, _rows} =
              from(e in Entry,
                where: e.tenant_id == ^tenant_id and e.channel == ^channel,
                where: not is_nil(e.destination)
              )
              |> Repo.delete_all(prefix: prefix)

            {:ok, count}
          else
            {:ok, 0}
          end
        end)
        |> Multi.run(:audit, fn repo, %{deleted: count} ->
          # A removal that removed nothing writes no audit row: there was no
          # change to account for.
          if count > 0 do
            Audit.insert_entry(
              repo,
              %{
                actor_id: actor_id,
                action: "outbound_destinations.remove",
                resource_type: "outbound_destination",
                resource_id: resource_id(channel, destination),
                before_state: %{"channel" => channel, "destination" => destination},
                after_state: nil
              },
              prefix
            )
          else
            {:ok, :nothing_removed}
          end
        end)

      case Repo.transaction(multi) do
        {:ok, %{deleted: 0}} -> {:ok, :absent}
        {:ok, _result} -> {:ok, :removed}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_schema_name}
      {:error, :invalid_channel} -> {:error, :invalid_channel}
      {:error, :invalid_destination} -> {:error, :invalid_destination}
    end
  rescue
    # A tenant not yet migrated (no table): a typed error, not a raw 500.
    _e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :allow_list_unavailable}
  end

  # The row of one entry of the list, or `nil`.
  defp existing(prefix, tenant_id, channel, nil) do
    from(e in Entry,
      where: e.tenant_id == ^tenant_id and e.channel == ^channel and is_nil(e.destination)
    )
    |> Repo.one(prefix: prefix)
  end

  defp existing(prefix, tenant_id, channel, destination) do
    from(e in Entry,
      where:
        e.tenant_id == ^tenant_id and e.channel == ^channel and
          e.destination == ^destination
    )
    |> Repo.one(prefix: prefix)
  end

  # The same lookup, with the tenant derived from the prefix -- the shape the
  # `add/4` rescue needs (the transaction that raised is gone, so the derived
  # tenant id has to be read again).
  defp existing_for_prefix(prefix, channel, destination) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      existing(prefix, tenant_id, channel, destination)
    else
      {:error, :invalid_schema_name} -> nil
    end
  end

  defp resource_id(channel, nil), do: channel
  defp resource_id(channel, destination), do: "#{channel}:#{destination}"

  @doc """
  THE CHECK: may the tenant of `prefix` reach `destination` on `channel`?

  `:ok` when the channel is on the list and the destination (when there is
  one) is on the list too. `{:error, :channel_not_allowed}` and
  `{:error, :destination_not_allowed}` when it is not, and
  `{:error, :allow_list_unavailable}` when the list cannot be read -- a list
  that cannot be read allows NOTHING (fail closed).

  A destination that cannot be READ (a placeholder host, `:unknown_host`) is
  refused as `:destination_not_allowed`: a target nobody can check is a target
  nobody may reach.

  `{:error, :invalid_schema_name}` when the prefix names no tenant: that is a
  CALLER's mistake, not a list that is empty, and the caller (the dispatcher)
  answers it as the invalid schema it is.

  The tenant is DERIVED from the prefix the list lives in, never taken from the
  caller (INV-1 (c)).
  """
  @spec check(String.t(), term(), destination()) :: :ok | {:error, error()}
  def check(prefix, channel, destination) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, channel} <- normalize_channel(channel),
         {:ok, destination} <- normalize_destination(channel, destination) do
      if channel_allowed?(prefix, tenant_id, channel) do
        if is_nil(destination) or destination_allowed?(prefix, tenant_id, channel, destination) do
          :ok
        else
          {:error, :destination_not_allowed}
        end
      else
        {:error, :channel_not_allowed}
      end
    else
      {:error, :invalid_channel} -> {:error, :channel_not_allowed}
      {:error, :invalid_destination} -> {:error, :destination_not_allowed}
      {:error, :invalid_schema_name} -> {:error, :invalid_schema_name}
    end
  rescue
    _exception -> {:error, :allow_list_unavailable}
  end

  @doc """
  The OUTBOUND TARGET of one definition node: `{channel, destination}` or
  `nil` when the node sends nothing outside.

  A NOTIFICATION step sends on the channel its declaration names (`email`
  today, `file` with the file-channel adapter); its destination is read from
  a VARIABLE of the running instance, so it is NOT known at activation time
  and the destination is `nil` here -- the dispatch check reads it.

  An INLINE HTTP step (`endpoint` attribute) sends on the `http` channel; its
  destination is the host of the URL template, when the host is a literal. A
  DYNAMIC host (`{{variables.host}}`) cannot be checked against the list at
  all -- the list names hosts, not templates -- so it is `:unknown_host` here
  and the check REFUSES it: a target that cannot be checked is a target that
  is not allowed (the list is deny by default, and the rule is fail closed).
  """
  @spec node_target(map()) :: {channel(), destination()} | nil
  def node_target(%{attributes: attributes}) when is_map(attributes) do
    case Map.get(attributes, "notify") do
      raw when is_map(raw) ->
        case Letflow.Definitions.NotifyCalls.parse(raw) do
          {:ok, declaration} -> {notify_channel(declaration), nil}
          {:error, _code} -> nil
        end

      _other ->
        case Map.get(attributes, "endpoint") do
          url when is_binary(url) -> {"http", http_destination(url)}
          _other -> nil
        end
    end
  end

  def node_target(_node), do: nil

  @doc """
  Every CHANNEL the definition's own nodes use: the channels of a graph, in a
  stable order and without duplicates.

  A graph that cannot be read answers `[]`: a definition whose nodes cannot be
  read reaches nothing, so a caller that opens channels for it opens nothing.
  """
  @spec channels_of(map()) :: [channel()]
  def channels_of(graph_map) when is_map(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, %Graph{nodes: nodes}} ->
        nodes
        |> Enum.map(&node_target/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.sort()

      :error ->
        []
    end
  end

  @doc """
  Opens every CHANNEL the definition uses for the tenant of `prefix` -- and
  NOTHING else: a destination (a recipient domain, a host) is never opened
  here. A channel is the door; a destination is the address behind it, and the
  address stays a human decision (decision record G2 (c)).

  The actor is written to the audit log with the row, exactly as in `add/5`.
  The call is idempotent: a channel that is already on the list stays as it is.

  The caller is the platform's own SEED of a standard definition (T-2597,
  gap G14): a version that cannot send anything is never switched on, so the
  seed opens the transport its own version uses -- with the authority of an
  administrator who holds the narrow atom `:OutboundDestinationsManage`. The
  caller checks that authority; this function is the list's writer, not its
  gatekeeper.
  """
  @spec open_channels(String.t(), term(), map()) :: {:ok, [channel()]} | {:error, error()}
  def open_channels(prefix, actor_id, graph_map) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      Enum.reduce_while(channels_of(graph_map), {:ok, []}, fn channel, {:ok, opened} ->
        case add(prefix, actor_id, channel, nil) do
          {:ok, _entry} -> {:cont, {:ok, opened ++ [channel]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @grandfather_reason "grandfathered by G14"

  @doc """
  GRANDFATHERING (decision G2 (c), PM ruling 2026-11-24): lists the channels
  and the literal hosts that the tenant's ALREADY-ACTIVE definitions use, so
  they keep running when the allow-list arrives. Only NEW destinations are
  default-deny.

  Each row carries the id of the definition that used it and the reason
  `"grandfathered by G14"`; both are shown by `list/1`. A dynamic host (a
  template) is not listed: it cannot be checked, so it stays refused. The call
  is idempotent (an entry already listed stays as it is) and returns the number
  of rows it wrote. Called from the migration that creates the table; a tenant
  without active definitions gets nothing.
  """
  @spec grandfather(String.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def grandfather(prefix) when is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      now = DateTime.utc_now()

      rows =
        from(d in "process_definitions",
          where: d.status == "active",
          order_by: [asc: d.id],
          select: {d.id, d.graph}
        )
        |> Repo.all(prefix: prefix)
        |> Enum.flat_map(fn {definition_id, graph} -> grandfather_rows(definition_id, graph) end)
        |> Enum.uniq_by(fn {_id, channel, destination} -> {channel, destination} end)
        |> Enum.map(fn {definition_id, channel, destination} ->
          %{
            id: Ecto.UUID.generate(),
            tenant_id: tenant_id,
            channel: channel,
            destination: destination,
            definition_id: Ecto.UUID.cast!(definition_id),
            reason: @grandfather_reason,
            inserted_at: now
          }
        end)

      {count, _} =
        Repo.insert_all(Entry, rows, prefix: prefix, on_conflict: :nothing)

      if count > 0, do: grandfather_audit!(prefix, tenant_id, count)

      {:ok, count}
    end
  end

  # The backfill is a SYSTEM path (the migration calls it): no person, so the
  # actor is nil, as the role-scope backfill's entry is. One entry per tenant
  # that was widened; a tenant with no active outbound step gets none.
  defp grandfather_audit!(prefix, tenant_id, count) do
    attrs = %{
      actor_id: nil,
      action: "outbound_destinations.grandfathered",
      resource_type: "outbound_destinations",
      resource_id: tenant_id,
      before_state: nil,
      after_state: %{"source" => "migration", "reason" => @grandfather_reason, "rows" => count}
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> :ok
      {:error, _reason} -> raise RuntimeError, "outbound_destinations grandfather audit failed"
    end
  end

  # The channel row and the destination row of every node of one graph, with
  # the id of the definition that used them.
  defp grandfather_rows(definition_id, graph) when is_map(graph) do
    case Graph.from_map(graph) do
      {:ok, %Graph{nodes: nodes}} ->
        nodes
        |> Enum.map(&node_target/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn
          {channel, destination} when is_binary(destination) ->
            [{definition_id, channel, nil}, {definition_id, channel, destination}]

          {channel, _no_destination} ->
            [{definition_id, channel, nil}]
        end)

      :error ->
        []
    end
  end

  defp grandfather_rows(_definition_id, _graph), do: []

  @doc """
  The host of a URL template, lowercased, or `nil` when it has none.

  The byte bound and the UTF-8 check come FIRST (SF-01): `URI.parse/1` raises
  on a binary that is not valid UTF-8.
  """
  @spec http_host(term()) :: String.t() | nil
  def http_host(url) when is_binary(url) do
    if byte_size(url) <= @max_url_bytes and String.valid?(url) do
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) and host != "" ->
          if String.contains?(host, "{{") do
            nil
          else
            String.downcase(host)
          end

        _other ->
          nil
      end
    else
      nil
    end
  end

  def http_host(_url), do: nil

  # The DESTINATION of an inline HTTP step: the literal host of the URL, or
  # `:unknown_host` when the host is a placeholder. A placeholder host is not a
  # destination the list can name, so the check refuses it -- the same way it
  # refuses a destination it cannot read.
  defp http_destination(url) do
    cond do
      templated_host?(url) ->
        :unknown_host

      # SF-01: a URL over the byte cap (or not UTF-8) is unreadable, and an
      # unreadable target is refused, never waved through on the channel alone.
      byte_size(url) > @max_url_bytes or not String.valid?(url) ->
        :unknown_host

      true ->
        # No host at all: the URL is refused further down the line (the
        # rendered-URL rule of the engine), and the channel is checked here.
        http_host(url)
    end
  end

  # A URL whose HOST is a placeholder. The PATH may be a template -- that is
  # fine: the host is what the request reaches.
  defp templated_host?(url) when is_binary(url) do
    if byte_size(url) <= @max_url_bytes and String.valid?(url) do
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) -> String.contains?(host, "{{")
        _other -> false
      end
    else
      false
    end
  end

  defp templated_host?(_url), do: false

  # ── the shape of an entry ────────────────────────────────────────────────────────────────

  defp normalize_channel(channel)
       when is_binary(channel) and byte_size(channel) <= @max_channel_bytes do
    downcased = String.downcase(channel)

    if downcased in @channels do
      {:ok, downcased}
    else
      {:error, :invalid_channel}
    end
  end

  defp normalize_channel(_channel), do: {:error, :invalid_channel}

  # A destination is a DOMAIN (the mail channel) or a HOST (the HTTP channel):
  # a name, never an address of a person (INV-4). The file channel has no
  # destination at all -- it writes into the tenant's own area.
  defp normalize_destination("file", nil), do: {:ok, nil}
  defp normalize_destination("file", _other), do: {:error, :invalid_destination}

  defp normalize_destination(_channel, nil), do: {:ok, nil}

  defp normalize_destination(_channel, destination) when is_binary(destination) do
    # SF-01: the byte bound and the UTF-8 check come BEFORE any per-character
    # work (the lower-casing walks the value), and the value is lower-cased
    # before it is compared: a domain is case-insensitive, and the list stores
    # one spelling of it.
    cond do
      byte_size(destination) == 0 or byte_size(destination) > @max_destination_bytes ->
        {:error, :invalid_destination}

      not String.valid?(destination) ->
        {:error, :invalid_destination}

      true ->
        downcased = String.downcase(destination)

        cond do
          String.contains?(downcased, "@") ->
            # An ADDRESS, not a domain: the list holds domains, and an address
            # of a person is personal data the platform does not store (INV-4).
            {:error, :invalid_destination}

          String.contains?(downcased, "://") or String.contains?(downcased, "/") ->
            {:error, :invalid_destination}

          not valid_name?(downcased) ->
            {:error, :invalid_destination}

          true ->
            {:ok, downcased}
        end
    end
  end

  defp normalize_destination(_channel, _destination), do: {:error, :invalid_destination}

  # A domain or a host: dot-separated labels of letters, digits and hyphens,
  # no label starting or ending with a hyphen. No wildcard: a subdomain is its
  # own entry.
  defp valid_name?(name) do
    name
    |> String.split(".")
    |> Enum.all?(&valid_label?/1)
  end

  defp valid_label?(label) do
    label != "" and byte_size(label) <= 63 and
      not String.starts_with?(label, "-") and
      not String.ends_with?(label, "-") and
      String.match?(label, ~r/\A[a-z0-9-]+\z/)
  end

  # The channel of a parsed notification declaration. The ONE function both the
  # activation fence and the dispatcher use, so the dispatch-time channel can
  # never drift from the activation-time one. The `file` channel lands with the
  # file-channel adapter; a declaration with no channel is the mail channel.
  @doc false
  @spec notify_channel(map() | term()) :: String.t()
  def notify_channel(declaration) when is_map(declaration) do
    case Map.get(declaration, :channel) do
      channel when is_binary(channel) and byte_size(channel) <= @max_channel_bytes ->
        String.downcase(channel)

      # SF-01: an over-cap channel names nothing; it can never be on the list.
      channel when is_binary(channel) ->
        "invalid"

      _other ->
        "email"
    end
  end

  def notify_channel(_declaration), do: "email"

  # ── the reads of the list ────────────────────────────────────────────────────────────────

  defp channel_allowed?(prefix, tenant_id, channel) do
    query =
      from(e in Entry,
        where: e.tenant_id == ^tenant_id and e.channel == ^channel and is_nil(e.destination),
        select: count(e.id)
      )

    (Repo.one(query, prefix: prefix) || 0) > 0
  end

  defp destination_allowed?(prefix, tenant_id, channel, destination) do
    query =
      from(e in Entry,
        where:
          e.tenant_id == ^tenant_id and e.channel == ^channel and
            e.destination == ^destination,
        select: count(e.id)
      )

    (Repo.one(query, prefix: prefix) || 0) > 0
  end
end
