if Mix.target() == :rpi5 do
  defmodule Rumbex.Native do
    @moduledoc false
    @on_load :load_nif

    def load_nif do
      # without extension — Erlang will add .so itself
      path = Path.join(:code.priv_dir(:rumbex), "native/librumbex_smb_native")
      :erlang.load_nif(String.to_charlist(path), 0)
    end

    def connect(_unc, _user, _pass), do: :erlang.nif_error(:nif_not_loaded)
    def read_file(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def write_file(_conn, _path, _data), do: :erlang.nif_error(:nif_not_loaded)
    def list_dir(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def stat(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def mkdir_p(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def mkdir(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def exists(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def rm(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def file_stats(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)

    def rename(_conn, _old_path, _new_path, _replace_if_exists),
      do: :erlang.nif_error(:nif_not_loaded)
  end
else
  defmodule Rumbex.Native do
    use Rustler, otp_app: :rumbex, crate: "rumbex_smb_native"

    def connect(_unc, _user, _pass), do: :erlang.nif_error(:nif_not_loaded)
    def read_file(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def write_file(_conn, _path, _data), do: :erlang.nif_error(:nif_not_loaded)
    def list_dir(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def stat(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def mkdir_p(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def mkdir(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def exists(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def rm(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)
    def file_stats(_conn, _path), do: :erlang.nif_error(:nif_not_loaded)

    def rename(_conn, _old_path, _new_path, _replace_if_exists),
      do: :erlang.nif_error(:nif_not_loaded)
  end
end
