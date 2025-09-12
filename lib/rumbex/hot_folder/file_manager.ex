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
  We support: binaries, and maps with keys like :name/"name"/:filename and :type/:size.
  """
  @spec entry_to_name_size(String.t(), String.t(), String.t(), String.t(), term()) ::
          {String.t(), non_neg_integer()} | :skip

  def entry_to_name_size(url, u, p, dir, {name, type}) when is_binary(name) do
    case type do
      t when t in [:directory, "directory"] -> :skip
      _ -> stat_to_tuple(url, u, p, Path.join(dir, name))
    end
  end

  def entry_to_name_size(url, u, p, dir, entry) when is_binary(entry) do
    stat_to_tuple(url, u, p, Path.join(dir, entry))
  end

  def entry_to_name_size(url, u, p, dir, entry) when is_map(entry) do
    name =
      Map.get(entry, :name) || Map.get(entry, "name") || Map.get(entry, :filename) ||
        Map.get(entry, "filename")

    type = Map.get(entry, :type) || Map.get(entry, "type")
    size = Map.get(entry, :size) || Map.get(entry, "size")

    cond do
      is_binary(name) and type in [:directory, "directory"] ->
        :skip

      is_binary(name) and is_integer(size) and type in [:file, :regular, "file", nil] ->
        {name, size}

      is_binary(name) ->
        stat_to_tuple(url, u, p, Path.join(dir, name))

      true ->
        :skip
    end
  end

  def entry_to_name_size(_url, _u, _p, _dir, _), do: :skip

  defp stat_to_tuple(url, u, p, full) do
    case Rumbex.get_file_stats(url, u, p, full) do
      {:ok, %{type: t, size: size}} when t in [:file, :regular] -> {Path.basename(full), size}
      _ -> :skip
    end
  end

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

  def overwrite_move(url, u, p, from, to) do
    with :ok <- delete_if_exists(url, u, p, to) do
      Rumbex.move_file(url, u, p, from, to)
    end
  end

  def move_unique(url, u, p, from, to) do
    alt = Rumbex.HotFolder.FileFilter.unique_variant(to)

    case Rumbex.move_file(url, u, p, from, alt) do
      :ok -> {:ok, alt}
      other -> other
    end
  end

  def delete_if_exists(url, u, p, path) do
    case Rumbex.exists(url, u, p, path) do
      {:ok, :file} -> Rumbex.delete_file(url, u, p, path)
      {:ok, :directory} -> {:error, :target_is_directory}
      _ -> :ok
    end
  end

  @doc """
  Check if a file should be processed by the hot folder.
  
  Returns true if file exists and is accessible (not in delete-pending state).
  This helps avoid processing files that have been deleted by other connections.
  """
  def should_process?(url, u, p, path) do
    case {Rumbex.exists(url, u, p, path), Rumbex.is_accessible(url, u, p, path)} do
      {{:ok, :file}, {:ok, true}} -> true
      _ -> false
    end
  end
end
