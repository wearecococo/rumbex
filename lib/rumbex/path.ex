defmodule Rumbex.Path do
  @moduledoc false

  # "smb://host/share/rel" -> {"\\host\share", "rel"}
  @spec parse_smb_url!(String.t()) :: {String.t(), String.t()}
  def parse_smb_url!("smb://" <> _ = url) do
    uri = URI.parse(url)
    host = uri.host || raise ArgumentError, "bad SMB url: host is missing"

    [share | rest] =
      (uri.path || "")
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> case do
        [sh | _] = all when sh != "" -> all
        _ -> raise ArgumentError, "bad SMB url: share is missing"
      end

    {"\\\\#{host}\\#{share}", Enum.join(rest, "/")}
  end

  # "\\host\share\rel" -> {"\\host\share", "rel"}
  def parse_smb_url!(<<"\\\\", _::binary>> = unc) do
    ["" | rest] = String.split(unc, "\\")

    case rest do
      [_empty, host, share | tail] -> {"\\\\#{host}\\#{share}", Enum.join(tail, "/")}
      _ -> raise ArgumentError, "bad UNC"
    end
  end

  @spec norm(String.t()) :: String.t()
  def norm(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_leading("\\")
  end
end
