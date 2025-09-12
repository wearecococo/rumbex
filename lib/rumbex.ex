defmodule Rumbex do
  @moduledoc """
  UNIFIED public API for SMB client.

  - Under the hood, it automatically creates/reuses pools by key (UNC, username, password).
  - You don't need to explicitly "connect": any operation ensures the required pool is up.
  - Paths are always **relative to the share root** (separators `/` and `\\` are normalized).

  ⚠️ Deletion: server uses DELETE_ON_CLOSE — object may remain visible
  while handles are open.
  """

  alias Rumbex.Path
  alias Rumbex.Pool
  alias Rumbex.PoolSupervisor

  @registry Rumbex.Registry

  # ───────── Public functions ─────────

  @doc """
  (Optional) Explicitly prepare a pool for (url_or_unc, username, password).
  You don't need to call this — any operations below will call this automatically.
  """
  @spec connect(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect(url_or_unc, username, password, opts \\ []) do
    with {:ok, _name} <- ensure_pool(url_or_unc, username, password, Keyword.get(opts, :size, 5)) do
      :ok
    end
  end

  @spec list_dir(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [{String.t(), :file | :directory}]} | {:error, term()}
  def list_dir(url_or_unc, username, password, path \\ "/"),
    do: call_pool(url_or_unc, username, password, {:list_dir, path})

  @spec read_file(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def read_file(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:read_file, path})

  @spec write_file(String.t(), String.t(), String.t(), String.t(), iodata()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def write_file(url_or_unc, username, password, path, data),
    do: call_pool(url_or_unc, username, password, {:write_file, path, data})

  @spec upload_file(String.t(), String.t(), String.t(), Path.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upload_file(url_or_unc, username, password, local_path, remote_path),
    do: call_pool(url_or_unc, username, password, {:upload_file, local_path, remote_path})

  @spec download_file(String.t(), String.t(), String.t(), String.t(), Path.t()) ::
          :ok | {:error, term()}
  def download_file(url_or_unc, username, password, remote_path, local_path),
    do: call_pool(url_or_unc, username, password, {:download_file, remote_path, local_path})

  @spec mkdir(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def mkdir(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:mkdir, path})

  @spec mkdir_p(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def mkdir_p(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:mkdir_p, path})

  @spec move_file(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def move_file(url_or_unc, username, password, from, to),
    do: call_pool(url_or_unc, username, password, {:move_file, from, to})

  @spec get_stat(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{size: non_neg_integer(), type: :file | :directory}} | {:error, term()}
  def get_stat(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:get_stat, path})

  @spec get_file_stats(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_file_stats(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:get_file_stats, path})

  @spec exists(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, :file | :directory | :not_found} | {:error, term()}
  def exists(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:exists, path})

  @doc "Delete a file or empty directory immediately"
  @spec delete_file(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(url_or_unc, username, password, path),
    do: call_pool(url_or_unc, username, password, {:delete_file, path})

  @doc "Stop and remove the pool for the combination (url_or_unc, username, password)."
  @spec stop_pool(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def stop_pool(url_or_unc, username, password) do
    {unc, _} = Path.parse_smb_url!(url_or_unc)
    name = pool_name(unc, username, password)

    case Registry.lookup(@registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(PoolSupervisor, pid)
      [] -> :ok
    end
  end

  # ───────── Internal: ensure + pool call ─────────

  defp call_pool(url_or_unc, username, password, msg) do
    with {:ok, name} <- ensure_pool(url_or_unc, username, password) do
      GenServer.call(via(name), msg, :infinity)
    end
  end

  @spec ensure_pool(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, atom()} | {:error, term()}
  defp ensure_pool(url_or_unc, username, password, size \\ 5) do
    {unc, _rel} = Path.parse_smb_url!(url_or_unc)
    name = pool_name(unc, username, password)

    case Registry.lookup(@registry, name) do
      [{_pid, _}] ->
        {:ok, name}

      [] ->
        spec = %{
          id: name,
          start:
            {Pool, :start_link,
             [[name: via(name), url: unc, username: username, password: password, size: size]]}
        }

        case DynamicSupervisor.start_child(PoolSupervisor, spec) do
          {:ok, _pid} -> {:ok, name}
          {:error, {:already_started, _pid}} -> {:ok, name}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e in ArgumentError -> {:error, e.message}
    e in ErlangError -> {:error, e.original}
  end

  defp pool_name(unc, user, pass) do
    fp = :crypto.hash(:sha256, [unc, "\n", user, "\n", pass]) |> Base.encode16(case: :lower)
    :"smb_pool_#{fp}"
  end

  defp via(name), do: {:via, Registry, {@registry, name}}
end
