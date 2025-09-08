defmodule Rumbex.HotFolder.FileManager do
  @moduledoc """
  File manager for the hot folder.
  """
  alias Rumbex

  def ensure_layout!(url, u, p, base, folders) do
    Enum.each(folders, fn {_k, rel} ->
      full = join(base, rel)
      _ = Rumbex.mkdir_p(url, u, p, full)
    end)

    :ok
  end

  @spec list_files(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, list()} | {:error, term()}
  def list_files(url, u, p, dir) do
    with {:ok, entries} <- Rumbex.list_dir(url, u, p, dir) do
      {:ok, Enum.reject(entries, &dir?/1)}
    end
  end

  @doc """
  Extract a basic file tuple {name, size} from entry returned by `Rumbex.list_dir/4`.
  We support both `%{name:, type:, size:}` and string names (fallback to stat).
  """
  @spec entry_to_name_size(String.t(), String.t(), String.t(), String.t(), term()) ::
          {String.t(), non_neg_integer()} | :skip
  def entry_to_name_size(_url, _u, _p, _dir, %{name: name, type: :file, size: size})
      when is_binary(name),
      do: {name, size}

  def entry_to_name_size(_url, _u, _p, _dir, %{type: :directory}), do: :skip

  def entry_to_name_size(url, u, p, dir, name) when is_binary(name) do
    # Last resort — stat
    case Rumbex.get_file_stats(url, u, p, Path.join(dir, name)) do
      {:ok, %{type: :file, size: size}} -> {name, size}
      _ -> :skip
    end
  end

  def entry_to_name_size(_url, _u, _p, _dir, _), do: :skip
  def move(url, u, p, from, to), do: Rumbex.move_file(url, u, p, from, to)

  def write_error_sidecar(url, u, p, dest_path, reason) do
    err_path = dest_path <> ".error.txt"
    body = format_reason(reason)
    _ = Rumbex.write_file(url, u, p, err_path, body)
    :ok
  end

  defp dir?(%{type: :directory}), do: true
  defp dir?(_), do: false

  defp format_reason(reason) do
    inspect(reason, pretty: true, limit: :infinity, width: 120) <> "\n"
  end

  @spec join(String.t(), String.t()) :: String.t()
  def join(base, rel) do
    [base, rel]
    |> Path.join()
    |> normalize()
  end

  def normalize(path) do
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    Path.expand(path)
  end
end
