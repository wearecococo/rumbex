defmodule Rumbex.HotFolder.FileFilter do
  @moduledoc """
  Filter files by name and size.
  """

  @spec match?(String.t(), non_neg_integer(), map()) :: boolean()
  def match?(name, size, filters) do
    name_ok?(name, filters) and size_ok?(size, filters)
  end

  defp name_ok?(name, %{name_patterns: pats} = filters) do
    include = Enum.empty?(pats) or Enum.any?(pats, &Regex.match?(&1, name))

    exclude =
      case Map.get(filters, :exclude_patterns, []) do
        [] -> false
        ex -> Enum.any?(ex, &Regex.match?(&1, name))
      end

    ext_ok =
      case Map.get(filters, :extensions) do
        nil ->
          true

        list when is_list(list) ->
          ext = name |> Path.extname() |> String.downcase()
          Enum.member?(list, ext)
      end

    include and not exclude and ext_ok
  end

  defp size_ok?(size, %{min_size: min, max_size: :infinity}), do: size >= min
  defp size_ok?(size, %{min_size: min, max_size: max}), do: size >= min and size <= max
end
