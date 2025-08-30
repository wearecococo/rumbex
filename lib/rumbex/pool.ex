defmodule Rumbex.Pool do
  @moduledoc """
  Pool of SMB-connests to one share, without lambdas and magic wrappers.
  Round-robin by N connections. share-relative paths.
  """

  use GenServer
  alias Rumbex.Operations
  alias Rumbex.Path
  alias Rumbex.Native

  @type opt ::
          {:name, atom()} | {:url, String.t()} | {:username, String.t()} |
          {:password, String.t()} | {:size, pos_integer()}

  ## ===== Public API =====

  @spec start_link([opt]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @spec child_spec([opt]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker, restart: :permanent, shutdown: 5000
    }
  end

  # Операции. Все вызывают соответствующий handle_call без каких-либо анонимных функций.
  def list_dir(pool, path),      do: GenServer.call(pool, {:list_dir, path}, :infinity)
  def read_file(pool, path),     do: GenServer.call(pool, {:read_file, path}, :infinity)
  def write_file(pool, p, data), do: GenServer.call(pool, {:write_file, p, data}, :infinity)
  def upload_file(pool, lp, rp), do: GenServer.call(pool, {:upload_file, lp, rp}, :infinity)
  def download_file(pool, rp, lp), do: GenServer.call(pool, {:download_file, rp, lp}, :infinity)
  def mkdir(pool, path),         do: GenServer.call(pool, {:mkdir, path}, :infinity)
  def mkdir_p(pool, path),       do: GenServer.call(pool, {:mkdir_p, path}, :infinity)
  def move_file(pool, a, b),     do: GenServer.call(pool, {:move_file, a, b}, :infinity)
  def get_stat(pool, path),      do: GenServer.call(pool, {:get_stat, path}, :infinity)
  def get_file_stats(pool, path),do: GenServer.call(pool, {:get_file_stats, path}, :infinity)
  def exists(pool, path),        do: GenServer.call(pool, {:exists, path}, :infinity)
  def delete_file(pool, path),   do: GenServer.call(pool, {:delete_file, path}, :infinity)
  def refresh(pool, which \\ :all), do: GenServer.call(pool, {:refresh, which}, :infinity)

  ## ===== GenServer =====

  @impl GenServer
  def init(opts) do
    url  = Keyword.fetch!(opts, :url)
    user = Keyword.fetch!(opts, :username)
    pass = Keyword.fetch!(opts, :password)
    size = Keyword.get(opts, :size, 5) |> max(1)

    {unc, _rel} = Path.parse_smb_url!(url)
    conns = for _ <- 1..size, do: connect!(unc, user, pass)

    {:ok, %{unc: unc, user: user, pass: pass, conns: conns, next: 0}}
  rescue
    e in ArgumentError -> {:stop, e.message}
    e in ErlangError   -> {:stop, e.original}
    e in RuntimeError  -> {:stop, e.message}
  end

  # ---- handle_call: явные матчеры на каждую операцию ----

  @impl GenServer
  def handle_call({:list_dir, path}, _from, s) do
    {conn, s2} = checkout(s)
    reply = Operations.list_dir(conn, Path.norm(path))
    {:reply, reply, s2}
  end

  def handle_call({:read_file, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.read_file(conn, Path.norm(path)), s2}
  end

  def handle_call({:write_file, path, data}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.write_file(conn, Path.norm(path), IO.iodata_to_binary(data)), s2}
  end

  def handle_call({:upload_file, local, remote}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.upload_file(conn, local, Path.norm(remote)), s2}
  end

  def handle_call({:download_file, remote, local}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.download_file(conn, Path.norm(remote), local), s2}
  end

  def handle_call({:mkdir, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.mkdir(conn, Path.norm(path)), s2}
  end

  def handle_call({:mkdir_p, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.mkdir_p(conn, Path.norm(path)), s2}
  end

  def handle_call({:move_file, from, to}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.move_file(conn, Path.norm(from), Path.norm(to)), s2}
  end

  def handle_call({:get_stat, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.get_stat(conn, Path.norm(path)), s2}
  end

  def handle_call({:get_file_stats, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.get_file_stats(conn, Path.norm(path)), s2}
  end

  def handle_call({:exists, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.exists(conn, Path.norm(path)), s2}
  end

  def handle_call({:delete_file, path}, _f, s) do
    {conn, s2} = checkout(s)
    {:reply, Operations.delete_file(conn, Path.norm(path)), s2}
  end

  def handle_call({:refresh, :all}, _f, s) do
    case reconnect_all(s) do
      {:ok, s2} -> {:reply, :ok, s2}
      {:error, r} -> {:reply, {:error, r}, s}
    end
  end

  def handle_call({:refresh, idx}, _f, s) when is_integer(idx) and idx >= 0 do
    case reconnect_one(s, idx) do
      {:ok, s2} -> {:reply, :ok, s2}
      {:error, r} -> {:reply, {:error, r}, s}
    end
  end

  ## ===== internal =====

  defp checkout(%{conns: [one]} = s), do: {one, s}
  defp checkout(%{conns: conns, next: i} = s) do
    n = length(conns)
    idx = rem(i, n)
    {Enum.at(conns, idx), %{s | next: idx + 1}}
  end

  defp reconnect_all(%{unc: unc, user: u, pass: p, conns: conns} = s) do
    new = Enum.map(conns, fn _ -> connect!(unc, u, p) end)
    {:ok, %{s | conns: new, next: 0}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp reconnect_one(%{unc: unc, user: u, pass: p, conns: conns} = s, idx) do
    if idx >= length(conns), do: {:error, :bad_index}, else: :ok
    new = List.replace_at(conns, idx, connect!(unc, u, p))
    {:ok, %{s | conns: new}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp connect!(unc, user, pass) do
    case Native.connect(unc, user, pass) do
      {:ok, conn} -> conn
      {:error, r} -> raise "connect_failed: #{inspect(r)}"
    end
  end
end
