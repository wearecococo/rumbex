defmodule Rumbex.HotFolder.FileFilter do
  @moduledoc """
  Filter files by name and size.
  """

  @spec match?(String.t(), non_neg_integer(), map()) :: boolean()
  def match?(name, size, filters) do
    name_ok?(name, filters) and size_ok?(size, filters)
  end

  def collision?(reason) when is_binary(reason),
    do: String.contains?(reason, "Object Name Collision")

  def collision?({:error, :exists}), do: true
  def collision?(_), do: false

  def unique_variant(path) do
    ext = Path.extname(path)
    base = Path.rootname(path, ext)
    ts = System.system_time(:millisecond)
    base <> "-" <> Integer.to_string(ts) <> ext
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

  defp size_ok?(size, filters) do
    min = Map.get(filters, :min_size, 0)
    max = Map.get(filters, :max_size, :infinity)

    if max == :infinity do
      size >= min
    else
      size >= min and size <= max
    end
  end
end
