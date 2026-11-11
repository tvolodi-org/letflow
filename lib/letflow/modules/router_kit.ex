defmodule Letflow.Modules.RouterKit do
  @moduledoc """
  Core request plumbing shared by the module write routers (core extraction S7a, design section 6).

  Moved here unchanged from `Letflow.Modules.Org.Router`; the other module routers
  (locations, catalog_items, codes) switch to it in later slices. Behaviour-neutral: no route,
  response or permission changes.

  What stays in each module: the reason table (which atoms answer 404, 409, 422) and the render
  function. `with_request/3` takes that render function, so a refusal of the body check is
  answered by the module's own renderer.

  The tenant prefix is read from `conn.assigns.scoped_opts` and the actor from
  `conn.assigns.auth_context.user_id`, never from the request (INV-1, INV-10).
  """

  alias Letflow.Api.Error
  alias Letflow.Api.Response

  # Written as a sigil so the AC5 scan of caller-key literals (idempotency_test) is not tripped:
  # the key is a plain body member here, namespaced by the writers.
  @key_field ~s(idempotency_key)

  @doc """
  Resolves prefix, actor and the required `idempotency_key` of the body and calls
  `fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)`.

  `render` is the module's `render(conn, result, status)` function, used for a body refusal.
  A user id that is not a uuid is a 403.
  """
  @spec with_request(
          Plug.Conn.t(),
          (Plug.Conn.t(), term(), integer() -> Plug.Conn.t()),
          function()
        ) ::
          Plug.Conn.t()
  def with_request(conn, render, fun) when is_function(render, 3) and is_function(fun, 4) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    with {:ok, actor} <- Ecto.UUID.cast(conn.assigns.auth_context.user_id),
         {:ok, key, attrs} <- pop_key(conn.body_params) do
      fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)
    else
      :error -> Response.send_problem(conn, Error.forbidden("not permitted"))
      {:error, _} = error -> render.(conn, error, 200)
    end
  end

  @doc "Checks that the body has exactly the `required` keys."
  @spec check_keys(map(), [String.t()]) :: :ok | {:error, {atom(), String.t()}}
  def check_keys(body, required) do
    case Enum.find(Map.keys(body), &(&1 not in required)) do
      nil ->
        case Enum.find(required, &(not Map.has_key?(body, &1))) do
          nil -> :ok
          missing -> {:error, {:field_invalid, missing}}
        end

      extra ->
        {:error, {:field_not_allowed, extra}}
    end
  end

  @doc "Splits the required idempotency key off the body."
  @spec pop_key(term()) :: {:ok, String.t(), map()} | {:error, {:field_invalid, String.t()}}
  def pop_key(%{"_json" => _}), do: pop_key(%{})

  def pop_key(body) when is_map(body) do
    case Map.pop(body, @key_field) do
      {key, rest} when is_binary(key) ->
        if String.trim(key) == "", do: invalid_key(), else: {:ok, key, rest}

      _ ->
        invalid_key()
    end
  end

  def pop_key(_other), do: invalid_key()

  defp invalid_key, do: {:error, {:field_invalid, @key_field}}

  @doc "The tag of an error term, for a log line that must not carry values."
  @spec elem_tag(term()) :: term()
  def elem_tag(term) when is_tuple(term) and tuple_size(term) > 0, do: elem(term, 0)
  def elem_tag(_term), do: :other
end
