defmodule Rumbex.HotFolder.StabilityChecker do
  @moduledoc """
  Check if a file is stable (has the same size) for a given number of checks and interval.
  """
  alias Rumbex

  @spec stable?(String.t(), String.t(), String.t(), String.t(), pos_integer(), pos_integer()) ::
          boolean()
  def stable?(url, u, p, path, checks, interval) do
    with {:ok, %{size: s0}} <- Rumbex.get_file_stats(url, u, p, path) do
      wait_all(url, u, p, path, s0, checks - 1, interval)
    else
      _ -> false
    end
  end

  defp wait_all(_url, _u, _p, _path, _prev, 0, _interval), do: true

  defp wait_all(url, u, p, path, prev, left, interval) do
    Process.sleep(interval)

    case Rumbex.get_file_stats(url, u, p, path) do
      {:ok, %{size: ^prev}} -> wait_all(url, u, p, path, prev, left - 1, interval)
      _ -> false
    end
  end
end
