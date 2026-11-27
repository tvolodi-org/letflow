defmodule Letflow.PlatformFunctions.ModuleFamily do
  @moduledoc """
  The MODULE FAMILY of the compiled platform function catalogue (D-204, the
  module-process conversion, sections 1.1 to 1.3).

  A module function becomes a catalogue entry with `family: "<module id>"`. The
  entry is DERIVED at compile time from the module's own write-handler
  registration (`Letflow.Modules.WriteHandlerSpec`), never written by hand: a
  module gets no second, hand-written list of functions.

  ## What a handler must declare to be a catalogue entry

  Four fields of the spec (D-204 1.2):

    * `permission` -- the atom the activator and the starter must hold. It
      must be one the module declares in its own `:permissions`. A handler
      WITHOUT a permission is NOT a catalogue entry: it stays on the old
      owner-stamp path (`module_writes`), so a module that has not been
      converted keeps its behaviour;
    * `outputs` -- the typed names the call returns;
    * `idempotency_inputs` -- the argument names that make a repeat the same
      call. Every one must be a REQUIRED argument of the handler, and a
      write-like handler must declare at least one: a key that may be absent
      does not identify a call;
    * `side_effect_classes` -- the classes of the call's side effects, out of
      `[:read, :write_module_record, :ledger_post]`.

  ## What the derivation reads off the handler

    * the name: `"<module id>.<handler name>"`;
    * the inputs: the handler's arguments, each `:start` (a module function's
      arguments come from the instance's start variables, never from a human
      task's completer -- the T-2430 rule by source class) and typed `:any`,
      because a write handler declares no types;
    * the version: the module's own version, for the entry travels with the
      module release it was derived from;
    * the tenant rule: a module entry is `platform_tenant_only: false`. It
      runs where the module is INSTALLED, not in the platform tenant only (see
      `Letflow.PlatformFunctions.ModuleTenantRule`).

  ## Never raises, fixed codes

  The derivation answers `{:ok, entries}` or `{:error, code}` with a code out
  of the closed list `codes/0`. It never raises: a manifest that cannot be
  turned into an entry is a REFUSAL, not a crash. The compiled catalogue turns
  a refusal into a compile error (the catalogue is code, and code that does
  not compile does not ship).

  The codes:

    * `:module_entry_handlers_invalid` -- the manifest's `:write_handlers` is
      not a list;
    * `:module_entry_permission_invalid` -- the declared permission is not an
      atom;
    * `:module_entry_permission_not_declared` -- the module does not declare
      that permission in its own `:permissions`;
    * `:module_entry_outputs_invalid` -- a malformed output;
    * `:module_entry_side_effect_class_missing` -- a handler in the module
      family with no side-effect class;
    * `:module_entry_side_effect_class_unknown` -- a class outside the closed
      set;
    * `:module_entry_side_effect_class_duplicate` -- the same class twice;
    * `:module_entry_side_effect_class_conflict` -- the classes contradict the
      handler (a pure read that posts a ledger, a read beside another class, a
      ledger post without a ledger registration);
    * `:module_entry_idempotency_input_unknown` -- an idempotency input that
      is not one of the handler's arguments;
    * `:module_entry_idempotency_input_optional` -- an idempotency input that
      is not a required argument;
    * `:module_entry_idempotency_missing` -- a write-like entry with no
      idempotency input;
    * `:module_entry_name_duplicate` -- two modules derived the same entry
      name.
  """

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.WriteHandlerSpec
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.Entry.Input
  alias Letflow.PlatformFunctions.Entry.Output
  alias Letflow.PlatformFunctions.Entry.SideEffect

  # The side-effect classes a module family entry may declare. `:read` is the
  # only one that is not write-like.
  @side_effect_classes [:read, :write_module_record, :ledger_post]

  @codes [
    :module_entry_handlers_invalid,
    :module_entry_permission_invalid,
    :module_entry_permission_not_declared,
    :module_entry_outputs_invalid,
    :module_entry_side_effect_class_missing,
    :module_entry_side_effect_class_unknown,
    :module_entry_side_effect_class_duplicate,
    :module_entry_side_effect_class_conflict,
    :module_entry_idempotency_input_unknown,
    :module_entry_idempotency_input_optional,
    :module_entry_idempotency_missing,
    :module_entry_name_duplicate
  ]

  @doc """
  The closed list of refusal codes the derivation answers with.
  """
  @spec codes() :: [atom()]
  def codes, do: @codes

  @doc """
  The module family's entries of every compiled module, sorted by name.

  `{:ok, entries}` or `{:error, code}` -- never a raise.
  """
  @spec entries() :: {:ok, [Entry.t()]} | {:error, atom()}
  def entries, do: entries_in(Catalog.entry_modules())

  @doc """
  The module family's entries of an EXPLICIT list of entry modules. The seam a
  test uses to derive against a manifest that never went through the compile
  time list (`Letflow.Modules.Catalog.write_handler_in/3` is the same seam for
  a single handler).

  `{:ok, entries}` or `{:error, code}` -- never a raise.
  """
  @spec entries_in([module()]) :: {:ok, [Entry.t()]} | {:error, atom()}
  def entries_in(entry_modules) when is_list(entry_modules) do
    case collect(entry_modules, []) do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1.name)}
      {:error, code} -> {:error, code}
    end
  end

  @doc """
  The entries ONE module contributes: the catalogue entries of the write
  handlers that declare a permission. A handler without one is no entry.

  `{:ok, entries}` or `{:error, code}` -- never a raise.
  """
  @spec module_entries(module()) :: {:ok, [Entry.t()]} | {:error, atom()}
  def module_entries(entry_module) when is_atom(entry_module) do
    manifest = entry_module.manifest()

    case Map.get(manifest, :write_handlers, []) do
      handlers when is_list(handlers) ->
        handlers
        |> Enum.filter(&catalogue_handler?/1)
        |> Enum.reduce_while({:ok, []}, fn handler, {:ok, acc} ->
          case derive(manifest, handler) do
            {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
            {:error, code} -> {:halt, {:error, code}}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, Enum.reverse(entries)}
          {:error, code} -> {:error, code}
        end

      _not_a_list ->
        {:error, :module_entry_handlers_invalid}
    end
  end

  @doc """
  True when a write handler is one of the MODULE FAMILY: it declares the
  permission the activator and the starter must hold.
  """
  @spec catalogue_handler?(term()) :: boolean()
  def catalogue_handler?(%WriteHandlerSpec{permission: permission}),
    do: not is_nil(permission)

  def catalogue_handler?(_other), do: false

  @doc """
  The entry ONE write handler of ONE manifest derives, or `{:error, code}`.
  Never raises.
  """
  @spec derive(map(), WriteHandlerSpec.t()) :: {:ok, Entry.t()} | {:error, atom()}
  def derive(manifest, %WriteHandlerSpec{} = handler) when is_map(manifest) do
    module_id = Map.get(manifest, :id)

    with :ok <- check_permission(manifest, handler),
         {:ok, outputs} <- check_outputs(handler),
         {:ok, classes} <- check_side_effect_classes(handler),
         :ok <- check_idempotency(handler, classes) do
      {:ok,
       %Entry{
         name: "#{module_id}.#{handler.name}",
         family: module_id,
         version: Map.get(manifest, :version, "1"),
         inputs: inputs(handler),
         outputs: outputs,
         permission: handler.permission,
         side_effects: side_effects(handler, classes),
         idempotency_key: handler.idempotency_inputs,
         platform_tenant_only: false
       }}
    end
  end

  def derive(_manifest, _handler), do: {:error, :module_entry_handlers_invalid}

  # ── the collection ──────────────────────────────────────────────────────────────────────

  defp collect(entry_modules, acc) do
    Enum.reduce_while(entry_modules, {:ok, acc}, fn entry_module, {:ok, acc} ->
      case module_entries(entry_module) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        {:error, code} -> {:halt, {:error, code}}
      end
    end)
    |> case do
      {:ok, entries} -> check_names(entries)
      {:error, code} -> {:error, code}
    end
  end

  # Two modules with the same id would derive the same entry name: the
  # catalogue names one function once, so the derivation refuses.
  defp check_names(entries) do
    names = Enum.map(entries, & &1.name)

    if Enum.uniq(names) == names do
      {:ok, entries}
    else
      {:error, :module_entry_name_duplicate}
    end
  end

  # ── the checks ─────────────────────────────────────────────────────────────────────────

  # The permission must be an atom the module ITSELF declares: a module family
  # entry names a permission of its own module, never a foreign one.
  defp check_permission(manifest, handler) do
    cond do
      not is_atom(handler.permission) ->
        {:error, :module_entry_permission_invalid}

      handler.permission not in Map.get(manifest, :permissions, []) ->
        {:error, :module_entry_permission_not_declared}

      true ->
        :ok
    end
  end

  defp check_outputs(handler) do
    outputs = handler.outputs

    if is_list(outputs) and well_formed_outputs?(outputs) and unique_output_names?(outputs) do
      {:ok, Enum.map(outputs, &%Output{name: &1.name, type: &1.type})}
    else
      {:error, :module_entry_outputs_invalid}
    end
  end

  defp well_formed_outputs?(outputs) do
    Enum.all?(outputs, fn output ->
      is_map(output) and not is_struct(output) and map_size(output) == 2 and
        Map.has_key?(output, :name) and Map.has_key?(output, :type) and
        is_binary(Map.get(output, :name)) and Map.get(output, :name) != "" and
        is_atom(Map.get(output, :type))
    end)
  end

  defp unique_output_names?(outputs) do
    names = Enum.map(outputs, &Map.get(&1, :name))
    Enum.uniq(names) == names
  end

  # The classes say what the call does. They must agree with the handler:
  # a pure read posts no ledger, and a ledger post names a registration.
  defp check_side_effect_classes(handler) do
    classes = handler.side_effect_classes

    cond do
      not is_list(classes) ->
        {:error, :module_entry_side_effect_class_unknown}

      classes == [] ->
        {:error, :module_entry_side_effect_class_missing}

      Enum.any?(classes, &(&1 not in @side_effect_classes)) ->
        {:error, :module_entry_side_effect_class_unknown}

      Enum.uniq(classes) != classes ->
        {:error, :module_entry_side_effect_class_duplicate}

      :read in classes and length(classes) > 1 ->
        {:error, :module_entry_side_effect_class_conflict}

      :read in classes and not is_nil(handler.posts_ledger) ->
        {:error, :module_entry_side_effect_class_conflict}

      :ledger_post in classes and is_nil(handler.posts_ledger) ->
        {:error, :module_entry_side_effect_class_conflict}

      true ->
        {:ok, classes}
    end
  end

  # The idempotency key names the arguments that make a repeat the same call:
  # every one of them must be an argument of the handler, and a required one
  # (a key that may be absent does not identify a call). A write-like entry
  # must declare one: without a key a repeat cannot be told from a new call.
  defp check_idempotency(handler, classes) do
    inputs = handler.idempotency_inputs
    args = handler.args

    cond do
      not is_list(inputs) or not is_map(args) ->
        {:error, :module_entry_idempotency_input_unknown}

      Enum.any?(inputs, &(&1 not in Map.keys(args))) ->
        {:error, :module_entry_idempotency_input_unknown}

      Enum.any?(inputs, &(not required_arg?(args, &1))) ->
        {:error, :module_entry_idempotency_input_optional}

      write_like?(classes) and inputs == [] ->
        {:error, :module_entry_idempotency_missing}

      true ->
        :ok
    end
  end

  defp required_arg?(args, name) do
    case Map.get(args, name) do
      %{required: required} -> required == true
      _other -> false
    end
  end

  defp write_like?(classes), do: Enum.any?(classes, &(&1 != :read))

  # ── the entry's own parts ──────────────────────────────────────────────────────────────

  # The handler's arguments, sorted by name. A module function's arguments come
  # from the instance's start variables (`:start`): a human task's completer
  # may never decide what a module function writes.
  defp inputs(handler) do
    handler.args
    |> Enum.map(fn {name, spec} ->
      %Input{
        name: name,
        type: :any,
        required: Map.get(spec, :required, false) == true,
        source_class: :start
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp side_effects(handler, classes) do
    Enum.map(classes, fn class ->
      %SideEffect{text: side_effect_text(class, handler), class: class}
    end)
  end

  defp side_effect_text(:read, _handler),
    do: "reads the module's own records and writes nothing"

  defp side_effect_text(:write_module_record, handler),
    do: "writes the module's own records (#{Enum.join(handler.targets, ", ")})"

  defp side_effect_text(:ledger_post, handler),
    do: "posts a ledger entry (#{handler.posts_ledger})"
end
