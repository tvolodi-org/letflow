defmodule Letflow.Modules.LedgerRegistration do
  @moduledoc """
  REQ-684 / GH #3698 (decision 0073, note 14.3): validation of the optional top-level manifest key
  `:ledger`, a map `registration name => registration`. `Letflow.Modules.Catalog.validate/2` calls
  `validate/3` as rule 18, its last rule (the words "rule 12" in decision 0073 and the design note
  mean this rule: rule 12 was the next free number when they were written).

  Pure: it reads the manifest, the list of known manifests and the entry module atom it is
  given; it never reads a database and never creates an atom. It is inside the Rule 7 and 7b scope
  of `mix letflow.check_boundaries` (domain-neutral words only, no other `Letflow.Modules.*`
  reference), which is why the caller hands it everything instead of this file naming the catalog.

  ## Registration shape

      %{ledger_ids: {:fixed, [String.t()]},                       # {:instances, _} is refused
        slots: [%{name: String.t(), format: :uuid | :token, required: boolean()}],   # 1..8
        causes: %{String.t() => %{sign_rule: :positive | :negative | :zero_sum_by_slot_1 | :any,
                                  reason_required: boolean()}},
        permissions: %{post: atom(), reverse: atom(), read: atom(), reconcile: atom()},
        policy: {module(), :declare},
        # optional:
        key_bounds: [%{when_slot_nonempty: String.t(), max_on_hand: String.t()}],
        scope_slot: String.t() | nil,
        max_event_lateness_hours: 1..720,                         # absent reads as 96
        error_aliases: %{String.t() => String.t()},
        units: [String.t()]}

  ## Errors

  `{:error, {:invalid_ledger_registration, name, reason}}`, the first failure, registrations visited
  in sorted name order. One closed reason per check, in this order: `:shape` (slice-local: input
  that is not the shape above at all, so no arbitrary term can crash validation), `:instances_not_enabled`,
  `:ledger_id_form`, `:ledger_id_overlap`, `:slots`, `:causes`, `:key_bounds`, `:scope_slot`,
  `:lateness`, `:units`, `:policy`, `:permissions`, `:auditor_or_candidate_post`, `:error_aliases`.
  A permission atom that is a core permission is refused earlier, by rule 3 of the catalog
  (`:core_permission_collision`), because every permission named here must be in the manifest's own
  `:permissions`. Slots being append-only against the installed registration is not checked here
  (no installed registration is in hand; module upgrade, REQ-640 / slice L4).
  """

  alias Letflow.Ledger.Codes

  @registration_keys [
    :ledger_ids,
    :slots,
    :causes,
    :permissions,
    :policy,
    :key_bounds,
    :scope_slot,
    :max_event_lateness_hours,
    :error_aliases,
    :units
  ]
  @required_keys [:ledger_ids, :slots, :causes, :permissions, :policy]

  @name_format ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @suffix_format ~r/\A[a-z0-9-]{1,32}\z/
  @alias_format ~r/\A[a-z_]{1,48}\z/
  @unit_format ~r/\A[a-z0-9._:-]{1,32}\z/
  @sign_rules [:positive, :negative, :zero_sum_by_slot_1, :any]
  @permission_keys [:post, :reverse, :read, :reconcile]
  @default_lateness 96

  @type reason ::
          :shape
          | :instances_not_enabled
          | :ledger_id_form
          | :ledger_id_overlap
          | :slots
          | :causes
          | :key_bounds
          | :scope_slot
          | :lateness
          | :units
          | :policy
          | :permissions
          | :auditor_or_candidate_post
          | :error_aliases

  @doc """
  Validates the `:ledger` key of `manifest`. `known_manifests` includes the manifest itself
  (overlap compares by `id`); `entry_module` is the module atom that carries the manifest, or `nil`.
  """
  @spec validate(map(), [map()], module() | nil) ::
          :ok | {:error, {:invalid_ledger_registration, String.t() | nil, reason()}}
  def validate(manifest, known_manifests, entry_module) when is_map(manifest) do
    case Map.fetch(manifest, :ledger) do
      :error ->
        :ok

      {:ok, ledger} when is_map(ledger) and not is_struct(ledger) ->
        ledger
        |> Enum.sort_by(fn {name, _} -> inspect(name) end)
        |> Enum.find_value(:ok, fn {name, registration} ->
          case check(name, registration, manifest, ledger, known_manifests, entry_module) do
            :ok -> nil
            {:error, reason} -> {:error, {:invalid_ledger_registration, display(name), reason}}
          end
        end)

      {:ok, _other} ->
        {:error, {:invalid_ledger_registration, nil, :shape}}
    end
  end

  def validate(_manifest, _known, _entry_module),
    do: {:error, {:invalid_ledger_registration, nil, :shape}}

  defp display(name) when is_binary(name), do: name
  defp display(_name), do: nil

  @doc """
  The plain-data form of one VALIDATED registration, as `Letflow.Ledger.post/1` reads it and as
  `Letflow.Ledger.Digest.registration_hash/1` can hash it: `ledger_ids` a list, `policy` a
  `%{module: mod, function: :declare}` map (JSON cannot encode the declared tuples), and the
  defaults filled in (`key_bounds: []`, `scope_slot: nil`, `max_event_lateness_hours: 96`,
  `error_aliases: %{}`); `units` stays absent when absent.
  """
  @spec to_plain(map()) :: map()
  def to_plain(registration) do
    {:fixed, ids} = registration.ledger_ids
    {module, :declare} = registration.policy

    base = %{
      ledger_ids: ids,
      slots: registration.slots,
      causes: registration.causes,
      permissions: registration.permissions,
      policy: %{module: module, function: :declare},
      key_bounds: Map.get(registration, :key_bounds) || [],
      scope_slot: Map.get(registration, :scope_slot),
      max_event_lateness_hours:
        Map.get(registration, :max_event_lateness_hours) || @default_lateness,
      error_aliases: Map.get(registration, :error_aliases) || %{}
    }

    case Map.get(registration, :units) do
      nil -> base
      units -> Map.put(base, :units, units)
    end
  end

  # ── one registration ─────────────────────────────────────────────────────────────────────

  defp check(name, registration, manifest, ledger, known, entry_module) do
    with :ok <- check_shape(name, registration),
         :ok <- check_instances(registration),
         :ok <- check_ledger_ids(registration, manifest),
         :ok <- check_overlap(name, registration, manifest, ledger, known),
         :ok <- check_slots(registration),
         :ok <- check_causes(registration),
         :ok <- check_key_bounds(registration),
         :ok <- check_scope_slot(registration),
         :ok <- check_lateness(registration),
         :ok <- check_units(registration),
         :ok <- check_policy(registration, entry_module),
         :ok <- check_permissions(registration, manifest),
         :ok <- check_auditor_or_candidate(registration, manifest) do
      check_aliases(name, registration, ledger, manifest, known)
    end
  end

  defp check_shape(name, registration) do
    cond do
      not (is_binary(name) and Regex.match?(@name_format, name)) -> {:error, :shape}
      not (is_map(registration) and not is_struct(registration)) -> {:error, :shape}
      Enum.any?(Map.keys(registration), &(&1 not in @registration_keys)) -> {:error, :shape}
      Enum.any?(@required_keys, &(not Map.has_key?(registration, &1))) -> {:error, :shape}
      true -> :ok
    end
  end

  defp check_instances(%{ledger_ids: {:instances, _}}), do: {:error, :instances_not_enabled}
  defp check_instances(_registration), do: :ok

  defp check_ledger_ids(%{ledger_ids: {:fixed, ids}}, manifest) when is_list(ids) and ids != [] do
    module_id = Map.get(manifest, :id)

    if Enum.all?(ids, &well_formed_id?(&1, module_id)) and Enum.uniq(ids) == ids,
      do: :ok,
      else: {:error, :ledger_id_form}
  end

  defp check_ledger_ids(_registration, _manifest), do: {:error, :ledger_id_form}

  # `<module_id>` or `<module_id>:<suffix>`; the module id is the exact segment before the first
  # colon, compared as a string (no pattern is built from input).
  defp well_formed_id?(id, module_id) when is_binary(id) and is_binary(module_id) do
    byte_size(id) <= 64 and
      case String.split(id, ":") do
        [segment] -> segment == module_id
        [segment, suffix] -> segment == module_id and Regex.match?(@suffix_format, suffix)
        _more -> false
      end
  end

  defp well_formed_id?(_id, _module_id), do: false

  defp check_overlap(name, %{ledger_ids: {:fixed, ids}}, manifest, ledger, known) do
    own_id = Map.get(manifest, :id)

    other_manifest_ids =
      for other <- known,
          is_map(other),
          Map.get(other, :id) != own_id,
          id <- [Map.get(other, :id) | ledger_ids_of(other)],
          do: id

    sibling_ids =
      for {other_name, other} <- ledger,
          other_name != name,
          id <- registration_ids(other),
          do: id

    if Enum.any?(ids, &(&1 in other_manifest_ids or &1 in sibling_ids)),
      do: {:error, :ledger_id_overlap},
      else: :ok
  end

  defp ledger_ids_of(manifest) do
    case Map.get(manifest, :ledger) do
      ledger when is_map(ledger) and not is_struct(ledger) ->
        Enum.flat_map(ledger, fn {_name, registration} -> registration_ids(registration) end)

      _other ->
        []
    end
  end

  defp registration_ids(%{ledger_ids: {:fixed, ids}}) when is_list(ids), do: ids
  defp registration_ids(_registration), do: []

  defp check_slots(%{slots: slots}) when is_list(slots) and length(slots) in 1..8 do
    names = for %{name: name} <- slots, do: name

    if Enum.all?(slots, &well_formed_slot?/1) and Enum.uniq(names) == names,
      do: :ok,
      else: {:error, :slots}
  end

  defp check_slots(_registration), do: {:error, :slots}

  defp well_formed_slot?(%{name: name, format: format, required: required} = slot)
       when not is_struct(slot) and map_size(slot) == 3,
       do:
         is_binary(name) and byte_size(name) in 1..64 and format in [:uuid, :token] and
           is_boolean(required)

  defp well_formed_slot?(_slot), do: false

  defp check_causes(%{causes: causes}) when is_map(causes) and not is_struct(causes) do
    if map_size(causes) > 0 and
         Enum.all?(causes, fn {name, cause} -> is_binary(name) and well_formed_cause?(cause) end),
       do: :ok,
       else: {:error, :causes}
  end

  defp check_causes(_registration), do: {:error, :causes}

  defp well_formed_cause?(%{sign_rule: rule, reason_required: required} = cause)
       when not is_struct(cause) and map_size(cause) == 2,
       do: rule in @sign_rules and is_boolean(required)

  defp well_formed_cause?(_cause), do: false

  defp slot_names(%{slots: slots}), do: for(%{name: name} <- slots, do: name)

  defp check_key_bounds(registration) do
    case Map.get(registration, :key_bounds, []) do
      bounds when is_list(bounds) ->
        names = slot_names(registration)

        if Enum.all?(bounds, &well_formed_bound?(&1, names)),
          do: :ok,
          else: {:error, :key_bounds}

      _other ->
        {:error, :key_bounds}
    end
  end

  defp well_formed_bound?(%{when_slot_nonempty: slot, max_on_hand: max} = bound, names)
       when not is_struct(bound) and map_size(bound) == 2,
       do: slot in names and bound_value?(max)

  defp well_formed_bound?(_bound, _names), do: false

  # A positive canonical decimal text that fits numeric(30,9): at most 9 fraction digits and 21
  # integer digits, no exponent form, no leading zeros (the same limits as the core check).
  defp bound_value?(max) when is_binary(max) do
    case Decimal.parse(max) do
      {%Decimal{coef: coef, exp: exp} = value, ""} when is_integer(coef) and is_integer(exp) ->
        Decimal.gt?(value, 0) and Decimal.to_string(value, :normal) == max and exp >= -9 and
          integer_digits(max) <= 21

      _other ->
        false
    end
  end

  defp bound_value?(_max), do: false

  defp integer_digits(text), do: text |> String.split(".") |> hd() |> byte_size()

  defp check_scope_slot(registration) do
    case Map.get(registration, :scope_slot) do
      nil ->
        :ok

      slot when is_binary(slot) ->
        if slot in slot_names(registration), do: :ok, else: {:error, :scope_slot}

      _other ->
        {:error, :scope_slot}
    end
  end

  defp check_lateness(registration) do
    case Map.fetch(registration, :max_event_lateness_hours) do
      :error -> :ok
      {:ok, hours} when is_integer(hours) and hours in 1..720 -> :ok
      {:ok, _other} -> {:error, :lateness}
    end
  end

  defp check_units(registration) do
    case Map.get(registration, :units) do
      nil ->
        :ok

      units when is_list(units) ->
        if Enum.all?(units, &(is_binary(&1) and Regex.match?(@unit_format, &1))),
          do: :ok,
          else: {:error, :units}

      _other ->
        {:error, :units}
    end
  end

  defp check_policy(%{policy: {module, :declare}}, entry_module)
       when is_atom(module) and is_atom(entry_module) and not is_nil(module) and
              not is_nil(entry_module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :declare, 2) and
         String.starts_with?(Atom.to_string(module), Atom.to_string(entry_module) <> "."),
       do: :ok,
       else: {:error, :policy}
  end

  defp check_policy(_registration, _entry_module), do: {:error, :policy}

  defp check_permissions(%{permissions: perms}, manifest)
       when is_map(perms) and not is_struct(perms) do
    declared = Map.get(manifest, :permissions)
    atoms = Enum.map(@permission_keys, &Map.get(perms, &1))

    if Enum.sort(Map.keys(perms)) == Enum.sort(@permission_keys) and is_list(declared) and
         Enum.all?(atoms, &(is_atom(&1) and not is_nil(&1) and &1 in declared)) and
         perms.reverse != perms.post,
       do: :ok,
       else: {:error, :permissions}
  end

  defp check_permissions(_registration, _manifest), do: {:error, :permissions}

  defp check_auditor_or_candidate(%{permissions: perms}, manifest) do
    grants = Map.get(manifest, :role_grants)

    refused? =
      Enum.any?([:TENANT_AUDITOR, :CANDIDATE], fn role ->
        granted = if is_map(grants), do: Map.get(grants, role, []), else: []
        is_list(granted) and (perms.post in granted or perms.reverse in granted)
      end)

    if refused?, do: {:error, :auditor_or_candidate_post}, else: :ok
  end

  defp check_aliases(name, registration, ledger, manifest, known) do
    case Map.get(registration, :error_aliases, %{}) do
      aliases when is_map(aliases) and not is_struct(aliases) ->
        values = Map.values(aliases)

        taken =
          for({other_name, other} <- ledger, other_name != name, v <- alias_values(other), do: v) ++
            for(
              other <- known,
              is_map(other),
              Map.get(other, :id) != Map.get(manifest, :id),
              v <- manifest_alias_values(other),
              do: v
            )

        if Enum.all?(aliases, fn {key, value} ->
             key in Codes.aliasable() and is_binary(value) and Regex.match?(@alias_format, value) and
               value not in Codes.reserved()
           end) and Enum.uniq(values) == values and Enum.all?(values, &(&1 not in taken)),
           do: :ok,
           else: {:error, :error_aliases}

      _other ->
        {:error, :error_aliases}
    end
  end

  defp manifest_alias_values(manifest) do
    case Map.get(manifest, :ledger) do
      ledger when is_map(ledger) and not is_struct(ledger) ->
        Enum.flat_map(ledger, fn {_name, registration} -> alias_values(registration) end)

      _other ->
        []
    end
  end

  defp alias_values(%{error_aliases: aliases}) when is_map(aliases) and not is_struct(aliases),
    do: Map.values(aliases)

  defp alias_values(_registration), do: []
end
