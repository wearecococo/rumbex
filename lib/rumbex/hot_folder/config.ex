defmodule Rumbex.HotFolder.Config do
  @moduledoc """
    Configuration for `Rumbex.HotFolder`.


    Mirrors the public knobs from `Sambex.HotFolder.Config`, adapted to Rumbex
    (direct-per-call credentials; optional pre-connect pool).


    Required:
    * `:handler` — either a 1‑arity function (&fun/1) or `{Mod, fun, extra_args}`


    Connection (pass-through to Rumbex.* calls):
    * `:url` — e.g. "smb://server/share"
    * `:username`
    * `:password`
    * `:pool_size` — integer > 0; used to pre-connect a pool (optional, default 2)


    Layout:
    * `:base_path` — prefix inside share (default "/")
    * `:folders` — %{incoming:, processing:, success:, errors:}


    Filters:
    * `:filters` => %{
      name_patterns: [~r/\.pdf$/i, ...],
      exclude_patterns: [~r/^\./],
      min_size: 0,
      max_size: :infinity,
      extensions: nil | [".pdf", ".txt"],
      mime_map: nil | %{".pdf" => "application/pdf"} # used only if you match by extension
      }

      Polling / stability / retries:
    * `:poll_interval` => %{initial: 1_000, max: 30_000, backoff_factor: 2.0}
    * `:stability` => %{checks: 2, interval: 1_000} # require N identical sizes
    * `:handler_timeout` (ms) default 300_000
    * `:max_retries` integer >= 0 (default 3)
  """

  @enforce_keys [:handler]

  defstruct url: nil,
            username: nil,
            password: nil,
            pool_size: 2,
            base_path: "/",
            folders: %{
              incoming: "incoming",
              processing: "processing",
              success: "success",
              errors: "errors"
            },
            filters: %{
              name_patterns: [],
              exclude_patterns: [~r/^\./, ~r/~$/],
              min_size: 0,
              max_size: :infinity,
              extensions: nil,
              mime_map: nil
            },
            poll_interval: %{initial: 2_000, max: 30_000, backoff_factor: 2.0},
            stability: %{checks: 2, interval: 1_000},
            handler: nil,
            handler_timeout: 300_000,
            max_retries: 3

  @type t :: %__MODULE__{
          url: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          pool_size: pos_integer(),
          base_path: String.t(),
          folders: %{
            incoming: String.t(),
            processing: String.t(),
            success: String.t(),
            errors: String.t()
          },
          filters: map(),
          poll_interval: %{initial: pos_integer(), max: pos_integer(), backoff_factor: number()},
          stability: %{checks: pos_integer(), interval: pos_integer()},
          handler: (map() -> {:ok, term()} | {:error, term()}) | {module(), atom(), list()},
          handler_timeout: pos_integer(),
          max_retries: non_neg_integer()
        }

  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = cfg), do: cfg

  def new(map) when is_map(map) do
    struct!(__MODULE__, map)
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{handler: nil}), do: raise(ArgumentError, "handler is required")

  def validate!(%__MODULE__{poll_interval: %{initial: i, max: m}} = _cfg) when i > m,
    do: raise(ArgumentError, "poll_interval.initial must be <= poll_interval.max")

  def validate!(cfg), do: cfg
end
