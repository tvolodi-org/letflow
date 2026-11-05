defmodule Letflow.Voice.Settings do
  @moduledoc """
  REQ-740: the platform settings of the voice service (phrase to stock draft).

  `config/runtime.exs` reads nine optional `LETFLOW_VOICE_*` variables into
  `config :letflow, :voice`. This module reads that app env at call time (so a test sets
  it per test) and answers a struct only when a step is fully configured; anything
  missing or unknown answers `:off`, which turns the step off so typed and scanned entry
  keep working with no provider.

  The API keys are platform env settings, like `LETFLOW_SMTP_PASSWORD`, not
  `Letflow.Secrets` references: `Secrets.resolve/2` refuses a reference owned by another
  party, so one platform key cannot be resolved for every caller (REQ-740,
  "DECIDED HERE"). INV-4: both structs hide `:api_key` from `inspect/1`.
  """

  defmodule Speech do
    @moduledoc "Speech-to-text settings. `inspect/1` hides the API key."
    @derive {Inspect, except: [:api_key]}
    @enforce_keys [:model, :base_url, :api_key]
    defstruct [:model, :base_url, :api_key]

    @type t :: %__MODULE__{model: String.t(), base_url: String.t(), api_key: String.t()}
  end

  defmodule Model do
    @moduledoc "Language-model settings. `inspect/1` hides the API key."
    @derive {Inspect, except: [:api_key]}
    @enforce_keys [:model, :base_url, :api_key, :json_mode]
    defstruct [:model, :base_url, :api_key, :json_mode]

    @type t :: %__MODULE__{
            model: String.t(),
            base_url: String.t(),
            api_key: String.t(),
            json_mode: :schema | :object | :prompt
          }
  end

  @default_timeout_ms 60_000

  @spec speech() :: {:ok, Speech.t()} | :off
  def speech do
    cfg = config()

    with "openai_transcriptions" <- Keyword.get(cfg, :stt_provider),
         model when is_binary(model) and model != "" <- Keyword.get(cfg, :stt_model),
         url when is_binary(url) and url != "" <- Keyword.get(cfg, :stt_base_url),
         key when is_binary(key) and key != "" <- Keyword.get(cfg, :stt_api_key) do
      {:ok, %Speech{model: model, base_url: url, api_key: key}}
    else
      _ -> :off
    end
  end

  @spec model() :: {:ok, Model.t()} | :off
  def model do
    cfg = config()

    with "openai_chat" <- Keyword.get(cfg, :llm_provider),
         model when is_binary(model) and model != "" <- Keyword.get(cfg, :llm_model),
         url when is_binary(url) and url != "" <- Keyword.get(cfg, :llm_base_url),
         key when is_binary(key) and key != "" <- Keyword.get(cfg, :llm_api_key),
         {:ok, mode} <- json_mode(Keyword.get(cfg, :llm_json_mode)) do
      {:ok, %Model{model: model, base_url: url, api_key: key, json_mode: mode}}
    else
      _ -> :off
    end
  end

  @spec timeout_ms() :: pos_integer()
  def timeout_ms do
    case Keyword.get(config(), :timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timeout_ms
    end
  end

  defp json_mode(nil), do: {:ok, :prompt}
  defp json_mode("schema"), do: {:ok, :schema}
  defp json_mode("object"), do: {:ok, :object}
  defp json_mode("prompt"), do: {:ok, :prompt}
  defp json_mode(_other), do: :error

  defp config, do: Application.get_env(:letflow, :voice, [])
end
