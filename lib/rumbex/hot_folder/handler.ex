defmodule Rumbex.HotFolder.Handler do
  @moduledoc """
  Call the handler function with the file info and timeout.
  """

  @spec call((map() -> any()) | {module(), atom(), list()}, map(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def call(fun, file_info, timeout) when is_function(fun, 1) do
    task = Task.async(fn -> fun.(file_info) end)
    await(task, timeout)
  end

  def call({m, f, extra}, file_info, timeout) when is_atom(m) and is_atom(f) and is_list(extra) do
    task = Task.async(fn -> apply(m, f, [file_info | extra]) end)
    await(task, timeout)
  end

  def call(other, _file_info, _timeout), do: {:error, {:bad_handler, other}}

  defp await(task, timeout) do
    try do
      case Task.await(task, timeout) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
        other -> {:ok, other}
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end
end
