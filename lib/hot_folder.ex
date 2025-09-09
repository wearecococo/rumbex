defmodule Rumbex.HotFolder do
  @moduledoc """
  A GenServer that polls an SMB directory over Rumbex and processes files one‑by‑one.


  ✅ Parity goals with `Sambex.HotFolder`:
  * sequential processing
  * base/incoming/processing/success/errors folders
  * regex / size filters + stability check
  * backoff polling with `poll_now/1`
  * `status/1`, `stats/1`, graceful `stop/2`


  Differences vs Sambex today:
  * Connection is implicit via `Rumbex` (pool per {url,username,password}).
  * No named connection registry (can be added later if we add `Rumbex.Connection`).


  """
  use GenServer
  alias Rumbex.HotFolder.{Config, FileFilter, FileManager, StabilityChecker, Handler}

  require Logger

  @type file_info :: %{path: String.t(), name: String.t(), size: non_neg_integer()}
  @type stats :: %{
          files_processed: non_neg_integer(),
          files_failed: non_neg_integer(),
          current_status: atom(),
          uptime: non_neg_integer(),
          last_poll: DateTime.t() | nil,
          current_interval: pos_integer()
        }

  # ——— Client API
  @spec start_link(Config.t() | map(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []), do: GenServer.start_link(__MODULE__, {config, opts}, opts)

  @spec poll_now(GenServer.server()) :: :ok | {:error, atom()}
  def poll_now(server), do: GenServer.call(server, :poll_now)

  @spec stats(GenServer.server()) :: stats()
  def stats(server), do: GenServer.call(server, :stats)

  @spec status(GenServer.server()) :: atom() | {atom(), String.t()}
  def status(server), do: GenServer.call(server, :status)

  @spec stop(GenServer.server(), term()) :: :ok
  def stop(server, reason \\ :normal), do: GenServer.stop(server, reason)

  # ——— Server state
  defmodule State do
    @moduledoc false
    defstruct cfg: nil,
              url: nil,
              u: nil,
              p: nil,
              base: nil,
              dirs: nil,
              poll: %{current: 2_000, last: nil},
              files_processed: 0,
              files_failed: 0,
              status: :starting,
              started_at: nil,
              current_file: nil
  end

  # ——— GenServer callbacks
  @impl true
  def init({config, _opts}) do
    cfg = config |> Config.new() |> Config.validate!()

    url = cfg.url || raise ArgumentError, ":url is required"
    u = cfg.username || raise ArgumentError, ":username is required"
    p = cfg.password || raise ArgumentError, ":password is required"

    # Pre-create connection pool (no-op if already exists)
    _ = safe_connect(url, u, p, cfg.pool_size)

    base = FileManager.normalize(cfg.base_path)

    dirs = %{
      incoming: FileManager.join(base, cfg.folders.incoming),
      processing: FileManager.join(base, cfg.folders.processing),
      success: FileManager.join(base, cfg.folders.success),
      errors: FileManager.join(base, cfg.folders.errors)
    }

    :ok = FileManager.ensure_layout!(url, u, p, base, cfg.folders)

    state = %State{
      cfg: cfg,
      url: url,
      u: u,
      p: p,
      base: base,
      dirs: dirs,
      poll: %{current: cfg.poll_interval.initial, last: nil},
      status: :starting,
      started_at: System.monotonic_time(:millisecond)
    }

    # kick off polling
    Process.send_after(self(), :poll, 0)
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, %State{} = s) do
    uptime = System.monotonic_time(:millisecond) - s.started_at

    stats = %{
      files_processed: s.files_processed,
      files_failed: s.files_failed,
      current_status: s.status,
      uptime: uptime,
      last_poll: s.poll.last,
      current_interval: s.poll.current
    }

    {:reply, stats, s}
  end

  @impl true
  def handle_call(:status, _from, %State{} = s) do
    reply =
      case s.status do
        {:processing, name} -> {:processing, name}
        other -> other
      end

    {:reply, reply, s}
  end

  @impl true
  def handle_call(:poll_now, _from, %State{} = s) do
    Process.send_after(self(), :poll, 0)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:poll, %State{status: {:processing, _}} = s) do
    # busy; re-schedule conservatively to avoid tight loop
    Process.send_after(self(), :poll, s.poll.current)
    {:noreply, s}
  end

  def handle_info(:poll, %State{} = s) do
    now = DateTime.utc_now()

    case discover_one(s) do
      {:ok, nil, s1} ->
        # nothing to do — backoff
        next = backoff(s1)

        s1 = %{s1 | poll: %{s1.poll | last: now, current: next}}
        {:noreply, s1, s1.poll.current}

      {:ok, {name, size, full_incoming_path}, s1} ->
        # process exactly one file; reset interval on any work
        s2 = %{
          s1
          | poll: %{s1.poll | current: s1.cfg.poll_interval.initial, last: now},
            status: {:processing, name},
            current_file: name
        }

        {:noreply, do_process_one(name, size, full_incoming_path, s2)}

      {:error, reason, s1} ->
        warn("poll error: #{inspect(reason)}")
        next = backoff(s1)

        s1 = %{s1 | poll: %{s1.poll | last: now, current: next}, status: :error}
        {:noreply, s1, s1.poll.current}
    end
  end

  @impl true
  def handle_info(:timeout, %State{} = s) do
    send(self(), :poll)
    {:noreply, s}
  end

  # ——— internals
  defp discover_one(%State{} = s) do
    # list incoming; pick first candidate that passes filters & stability
    with {:ok, entries} <- FileManager.list_files(s.url, s.u, s.p, s.dirs.incoming) do
      candidates =
        entries
        |> Enum.map(&FileManager.entry_to_name_size(s.url, s.u, s.p, s.dirs.incoming, &1))
        |> Enum.reject(&(&1 == :skip))
        |> Enum.filter(fn {name, size} -> FileFilter.match?(name, size, s.cfg.filters) end)

      case Enum.at(candidates, 0) do
        nil ->
          {:ok, nil, %{s | status: :polling}}

        {name, size} ->
          full_incoming = Path.join(s.dirs.incoming, name)

          stable? =
            StabilityChecker.stable?(
              s.url,
              s.u,
              s.p,
              full_incoming,
              s.cfg.stability.checks,
              s.cfg.stability.interval
            )

          if stable?,
            do: {:ok, {name, size, full_incoming}, %{s | status: :polling}},
            else: {:ok, nil, %{s | status: :polling}}
      end
    else
      {:error, reason} -> {:error, reason, s}
    end
  end

  defp do_process_one(name, size, full_incoming_path, %State{} = s) do
    processing_base = Path.join(s.dirs.processing, name)

    case FileManager.move_unique(s.url, s.u, s.p, full_incoming_path, processing_base) do
      {:ok, processing_path} ->
        # processing_path — unique path; name remains original (for success)
        handle_processing(name, size, processing_path, s)

      {:error, reason} ->
        warn("move to processing (unique) failed: #{inspect(reason)}")
        s = %{s | status: :error, current_file: nil}
        reschedule(s)
    end
  end

  defp handle_processing(name, size, processing_path, %State{} = s) do
    info = %{path: processing_path, name: name, size: size}

    case Handler.call(s.cfg.handler, info, s.cfg.handler_timeout) do
      {:ok, _res} ->
        # move to success
        dest_base = Path.join(s.dirs.success, name)

        case FileManager.move(s.url, s.u, s.p, processing_path, dest_base) do
          :ok ->
            s = %{s | files_processed: s.files_processed + 1, status: :polling, current_file: nil}
            reschedule(s)

          {:error, _reason} ->
            case FileManager.move_unique(s.url, s.u, s.p, processing_path, dest_base) do
              {:ok, alt} ->
                warn("dest exists, saved as #{Path.basename(alt)}")

                s = %{
                  s
                  | files_processed: s.files_processed + 1,
                    status: :polling,
                    current_file: nil
                }

                reschedule(s)

              {:error, move_reason} ->
                warn("move to success (unique) failed: #{inspect(move_reason)}")
                s = %{s | files_failed: s.files_failed + 1, status: :error, current_file: nil}
                reschedule(s)
            end
        end

      {:error, reason} ->
        # move to errors and drop sidecar
        if FileFilter.collision?(reason) do
          dest = Path.join(s.dirs.success, name)
          alt = FileFilter.unique_variant(dest)

          case FileManager.move(s.url, s.u, s.p, processing_path, alt) do
            :ok ->
              warn("dest exists, saved as #{alt}")

              s = %{
                s
                | files_processed: s.files_processed + 1,
                  status: :polling,
                  current_file: nil
              }

              reschedule(s)

            {:error, move_reason} ->
              warn("move to success (alt) failed: #{inspect(move_reason)}")
              s = %{s | files_failed: s.files_failed + 1, status: :error, current_file: nil}
              reschedule(s)
          end
        else
          warn("move to success failed: #{inspect(reason)}")
          s = %{s | files_failed: s.files_failed + 1, status: :error, current_file: nil}
          reschedule(s)
        end
    end
  end

  defp reschedule(%State{} = s) do
    Process.send_after(self(), :poll, s.poll.current)
    s
  end

  defp backoff(%State{} = s) do
    cur = s.poll.current
    max = s.cfg.poll_interval.max
    factor = s.cfg.poll_interval.backoff_factor
    next = min(max, max(10, round(cur * factor)))
    next
  end

  defp safe_connect(url, u, p, size) do
    try do
      Rumbex.connect(url, u, p, size: size)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp warn(msg), do: Logger.warning("[Rumbex.HotFolder] " <> msg)
end
