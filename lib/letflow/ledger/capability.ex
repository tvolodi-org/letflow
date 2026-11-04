defmodule Letflow.Ledger.Capability do
  @moduledoc """
  REQ-621 / GH #3469 part A, REQ-685 (slice L3b): the opaque input of `Letflow.Ledger.post/1`.

  A struct with `@enforce_keys`; `post/1` matches on the struct, so a plain map, a keyword list,
  `nil` or a struct of another module is refused. `mint/4` is the only function in `lib/` that
  builds one (the build step `Letflow.Ledger.HandlerPost` calls it); tests write the struct
  literal directly.

  * `prefix`: the tenant schema name, the only tenant input of the posting (INV-1);
  * `registration_name`, `registration`: plain registration data (slots, causes, key_bounds,
    units, max_event_lateness_hours), fetched from the compiled manifest, never from a caller;
  * `command`: the validated raw command map (carries `client_op_id`);
  * `posting`: the declarative posting (nil when `declare/2` did not produce one);
  * `subject_id`, `actor_id`: UUID strings; `origin_key`: the origin text of the entry;
  * `origin`, `instance_id`, `credential`: taken from the `HandlerContext` only, never from a
    command field; the run-time authority step reads them;
  * `deferred_refusal`: the first problem found at build time (nil when none), released only
    after the authority check so an unauthorised caller learns nothing about its command;
  * `read_disclosed` (REQ-686, not enforced, default false): set by the run-time authority step
    when the subject's roles also hold the registration's read permission; only then does an
    `insufficient_balance` refusal carry `available` per leg.
  """

  alias Letflow.Entities.HandlerContext
  alias Letflow.Entities.HandlerWrites

  @enforce_keys [
    :prefix,
    :registration_name,
    :registration,
    :command,
    :posting,
    :subject_id,
    :actor_id,
    :origin_key,
    :origin,
    :instance_id,
    :credential,
    :deferred_refusal
  ]
  defstruct @enforce_keys ++ [read_disclosed: false]

  @type deferred_refusal ::
          nil
          | {:typed, {:ledger_refused, atom(), String.t(), map()}}
          | {:forbidden, :declare_refused}
          | {:contract, atom()}

  @type t :: %__MODULE__{
          prefix: String.t(),
          registration_name: String.t(),
          registration: map(),
          command: map(),
          posting: map() | nil,
          subject_id: String.t(),
          actor_id: String.t(),
          origin_key: String.t(),
          origin: HandlerContext.origin(),
          instance_id: Ecto.UUID.t(),
          credential: atom() | nil,
          deferred_refusal: deferred_refusal(),
          read_disclosed: boolean()
        }

  @doc """
  Mints the capability of one posting. `build` is the build result `%{posting:, command:,
  deferred_refusal:}`; prefix, subject, actor, origin, instance and credential come from `ctx`
  only, the registration from the Catalog by the handler's module id. A context that is not a
  well-formed `HandlerContext` (or a registration that cannot be resolved) is `:invalid_context`.
  """
  @spec mint(HandlerContext.t(), String.t(), map(), String.t()) ::
          {:ok, t()} | {:error, :invalid_context}
  def mint(ctx, registration_name, %{command: command} = build, origin_key)
      when is_struct(ctx, HandlerContext) and is_binary(registration_name) and
             is_map(command) and is_binary(origin_key) do
    with %{prefix: prefix, origin: {tag, _id} = origin, handler: %{module_id: module_id}}
         when is_binary(prefix) and tag in [:task, :dispatch] and is_binary(module_id) <- ctx,
         {:ok, registration} <- HandlerWrites.__registration__(module_id, registration_name) do
      {:ok,
       %__MODULE__{
         prefix: prefix,
         registration_name: registration_name,
         registration: registration,
         command: command,
         posting: Map.get(build, :posting),
         subject_id: ctx.subject_id,
         actor_id: ctx.actor_id,
         origin_key: origin_key,
         origin: origin,
         instance_id: ctx.instance_id,
         credential: ctx.credential,
         deferred_refusal: Map.get(build, :deferred_refusal)
       }}
    else
      _unresolved -> {:error, :invalid_context}
    end
  end

  def mint(_ctx, _registration_name, _build, _origin_key), do: {:error, :invalid_context}
end
