defmodule Letflow.Ledger.Capability do
  @moduledoc """
  REQ-621 / GH #3469 part A: the opaque input of `Letflow.Ledger.post/1`.

  A struct with `@enforce_keys`; `post/1` matches on the struct, so a plain map, a keyword list,
  `nil` or a struct of another module is refused. In this slice there is no `mint` function and no
  builder: the struct literal is the only constructor and only tests write it (the server-side
  mint is slice L3).

  * `prefix`: the tenant schema name, the only tenant input of the posting (INV-1);
  * `registration_name`, `registration`: plain registration data (slots, causes, key_bounds,
    units, max_event_lateness_hours);
  * `command`: the validated raw command map (carries `client_op_id`);
  * `posting`: the declarative posting;
  * `subject_id`, `actor_id`: UUID strings; `origin_key`: the origin text of the entry.
  """

  @enforce_keys [
    :prefix,
    :registration_name,
    :registration,
    :command,
    :posting,
    :subject_id,
    :actor_id,
    :origin_key
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          prefix: String.t(),
          registration_name: String.t(),
          registration: map(),
          command: map(),
          posting: map(),
          subject_id: String.t(),
          actor_id: String.t(),
          origin_key: String.t()
        }
end
