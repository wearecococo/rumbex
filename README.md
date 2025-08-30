# Rumbex

rustler-based SMB lib, copies logic of `wearecococo/sambex`

# Rubbex.Native — SMB NIF for Elixir

A native wrapper around a Rust SMB client via `rustler`, exposing a minimal Elixir API to work with files and directories on an SMB share.

* Supports: read/write files, `mkdir -p`, existence checks, `stat`, directory listing, and delete.
* All NIFs are marked `DirtyIo` so they **do not block** BEAM schedulers.
* A connection is kept in a `ResourceArc`; inside is a thread-safe SMB `Client`.

---

## Rumbex — single public API

There is **one** public module: `Rumbex`.
Under the hood, it automatically creates/reuses a pool of connections per **(UNC, username, password)** binding.

> ⚠️ Deletion: the server sets `DELETE_ON_CLOSE`, so the object can remain visible in listings as long as the handles are open.

## Quick start

Run on host:
```
MIX_TARGET=host iex -S mix
```

Examples:
```
u   = "smb://127.0.0.1/private"
usr = "example2"
pwd = "badpass"

# (optional) prepare pool in advance
:ok = Rumbex.connect(u, usr, pwd, size: 6)

# Root listing
{:ok, items} = Rumbex.list_dir(u, usr, pwd, "/")

# mkdir (strict) and mkdir -p
:ok = Rumbex.mkdir(u, usr, pwd, "/dir-1")
:ok = Rumbex.mkdir_p(u, usr, pwd, "/dir-2/sub/leaf")

# Write/read
{:ok, 5}       = Rumbex.write_file(u, usr, pwd, "/dir-1/hello.txt", "hello")
{:ok, "hello"} = Rumbex.read_file(u, usr, pwd, "/dir-1/hello.txt")

# Upload / Download
{:ok, _} = Rumbex.upload_file(u, usr, pwd, "/tmp/local.csv", "/upload.csv")
:ok      = Rumbex.download_file(u, usr, pwd, "/upload.csv", "/tmp/download.csv")

# Atomic server-side move (within the same share)
:ok = Rumbex.move_file(u, usr, pwd, "/upload.csv", "/dir-2/upload-moved.csv")

# Stats
{:ok, %{size: 5, type: :file}} = Rumbex.get_stat(u, usr, pwd, "/dir-1/hello.txt")
{:ok, rich} = Rumbex.get_file_stats(u, usr, pwd, "/dir-1/hello.txt")
# rich ~ %{type: :file|:directory, size:, allocation_size:, nlink:, attributes:, mtime:, atime:, ctime:, btime:}

# Exists
{:ok, :file}      = Rumbex.exists(u, usr, pwd, "/dir-1/hello.txt")
{:ok, :directory} = Rumbex.exists(u, usr, pwd, "/dir-2")
{:ok, :not_found} = Rumbex.exists(u, usr, pwd, "/nope.txt")

# Delete file/empty directory
# Not working as exected for now, it does not really delete file, but marks it for deletion
:ok = Rumbex.delete_file(u, usr, pwd, "/dir-1/hello.txt")
:ok = Rumbex.delete_file(u, usr, pwd, "/dir-1")

# Stop pool (e.g., when changing password)
:ok = Rumbex.stop_pool(u, usr, pwd)

```

Check connection valid:
```elixir

{:ok, conn} =
  Rumbex.Native.connect("\\\\127.0.0.1\\private", "example2", "badpass")
```

---

## Error handling

---

## Notes & limitations

---

## License / scope

Was created for `wearecococo/connect` project. Adjust and use within this repository as needed.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `rumbex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:rumbex, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/rumbex>.

