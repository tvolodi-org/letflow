defmodule Letflow.Modules.Stock.ActorLabel do
  @moduledoc """
  GH 3735 R7: a person's name for a user id, for DISPLAY next to the id fields of the stock reads
  (`entered_by_label`, `posted_by_label`, `reversed_by_label`). The ids stay in the response; the label is
  additive and never replaces them.

  Rule, in order: the employee linked to the user (`Org.employee_for_user/2`) as `"code - full_name"` (the same
  text the web builds for an `org_employee` reference); else the user's non-blank `display_name`; else the
  `username`; else `nil` (the screen then shows its own "Another user" text, never the id).

  INV-1: every lookup carries the tenant `prefix`; a user of another tenant is not found (`nil`). INV-5: a miss and
  a forbidden id look the same (`nil`). INV-7: the id is cast to `Ecto.UUID` before it reaches the query, so a
  non-uuid string is `nil` without a query (and without the cast error a raw `get` would raise). No email, no
  other personal data in the label. A server read does not need the users-read permission of the caller: the label
  is derived from an id the caller already holds.
  """

  alias Letflow.Identity
  alias Letflow.Modules.Org

  @doc "The label of one user id in tenant schema `prefix`, or `nil`."
  @spec label(String.t(), term()) :: String.t() | nil
  def label(prefix, user_id) when is_binary(prefix) and is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> employee_label(prefix, uuid) || user_label(prefix, uuid)
      :error -> nil
    end
  end

  def label(_prefix, _user_id), do: nil

  @doc "A `%{user_id => label}` map for the distinct non-nil ids (one lookup per distinct id); ids with no label are left out."
  @spec labels(String.t(), [term()]) :: %{String.t() => String.t()}
  def labels(prefix, ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn id, acc ->
      case label(prefix, id) do
        nil -> acc
        text -> Map.put(acc, id, text)
      end
    end)
  end

  defp employee_label(prefix, uuid) do
    case Org.employee_for_user(prefix, uuid) do
      {:ok, emp} -> join(emp["code"], emp["full_name"])
      _ -> nil
    end
  end

  defp user_label(prefix, uuid) do
    case Identity.get_user(uuid, prefix: prefix) do
      {:ok, user} -> present(user.display_name) || present(user.username)
      _ -> nil
    end
  end

  defp join(code, name) do
    case {present(code), present(name)} do
      {nil, nil} -> nil
      {c, nil} -> c
      {nil, n} -> n
      {c, n} -> c <> " - " <> n
    end
  end

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
