defmodule Rumbex.Operations do
  @moduledoc false
  alias Rumbex.Native

  def list_dir(conn, rel) do
    try do
      Native.list_dir(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def read_file(conn, rel) do
    try do
      Native.read_file(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def write_file(conn, rel, bin) do
    try do
      case Native.write_file(conn, rel, bin) do
        :ok -> {:ok, byte_size(bin)}
        other -> other
      end
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def upload_file(conn, local_path, rel) do
    with {:ok, bin} <- File.read(local_path) do
      write_file(conn, rel, bin)
    end
  end

  def download_file(conn, rel, local_path) do
    case read_file(conn, rel) do
      {:ok, bin} -> File.write(local_path, bin)
      {:error, r} -> {:error, r}
    end
  end

  def mkdir(conn, rel) do
    try do
      Native.mkdir(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def mkdir_p(conn, rel) do
    try do
      Native.mkdir_p(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def move_file(conn, from_rel, to_rel) do
    try do
      Native.rename(conn, from_rel, to_rel, false)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def get_stat(conn, rel) do
    try do
      case Native.stat(conn, rel) do
        {:ok, {size, false}} -> {:ok, %{size: size, type: :file}}
        {:ok, {_0, true}} -> {:ok, %{size: 0, type: :directory}}
        other -> other
      end
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def get_file_stats(conn, rel) do
    try do
      case Native.file_stats(conn, rel) do
        {:ok, :not_found} -> {:error, :enoent}
        other -> other
      end
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def exists(conn, rel) do
    try do
      Native.exists(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def delete_file(conn, rel) do
    try do
      Native.rm(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end

  def is_accessible(conn, rel) do
    try do
      Native.is_accessible(conn, rel)
    rescue
      e in ErlangError -> {:error, e.original}
    end
  end
end
