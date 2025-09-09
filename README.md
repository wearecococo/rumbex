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
## Hot Folder

### What’s implemented now

- Hot folder loop over SMB: picks one file from incoming/, processes it, then moves to success/ (or errors/).

- Folder layout: incoming/, processing/, success/, errors/ (auto-created).

- Filters: by regex/extension and size; stability check via repeated equal file sizes.

- Backoff polling + manual wake-up via Rumbex.HotFolder.poll_now/1.

- Safe unique writes: if a destination already exists (common with SMB DELETE_PENDING), the file is saved with a -<millis> suffix.

Current default is on_success: :unique. (:overwrite can be enabled once robust delete is finalized.)


### Migration from Sambex.HotFolder

 - Replace Sambex.HotFolder.start_link(config) with Rumbex.HotFolder.start_link(config).

 - Reuse your existing config keys: base_path, folders, filters, stability, poll_interval, handler.

 - Connection goes through Rumbex (pool keyed by {url, username, password}) rather than Sambex connection registry.

 - For identical behavior on success moves later, you can switch on_success: :overwrite after delete is stable

 ### Troubleshooting (quick)

- Nothing happens

  - Run `Rumbex.HotFolder.poll_now(pid)`

  - Check status/stats:
    ```
    Rumbex.HotFolder.status(pid) # → :polling | {:processing, name} | :error
    Rumbex.HotFolder.stats(pid) # → counters + last poll + current interval
    ```

  - Verify discovery:
    ```
    Rumbex.list_dir(u, usr, pwd, "/incoming") and
    Rumbex.get_file_stats(u, usr, pwd, "/incoming/<file>")
    ```

  - For testing, set stability: %{checks: 1, interval: 100} and use a permissive filter (e.g., ~r/.*/).

- “Object Name Collision (0xc0000035)”

  - Expected on SMB when handles are open or delete is pending.
    The hot folder uses unique fallback: the file will be processed with a timestamped name; check processing/ and success/.

  - File is ignored

    - Confirm filters allow it (regex/extension) and min_size isn’t too high.

    - Hidden/tmp files (starting with . or ending with ~) are excluded by default — adjust      exclude_patterns if needed.

  - Connectivity / perms

    - Double-check URL and creds (smb://host[:port]/share), and that the user has write access to the share and all subfolders.

    - If you run a local Samba in Docker with a non-standard port, include it in the URL (e.g., smb://127.0.0.1:4453/private).

  - Want strict overwrite

    - Set on_success: :overwrite after delete is solid in Rumbex. Until then, prefer :unique to avoid stuck moves on DELETE_PENDING.

### Notes / Roadmap

Current MWP intentionally avoids delete to stay resilient on SMB servers that keep DELETE_PENDING.

Planned: robust delete with retries + on_success: :overwrite and :idempotent_if_same_size.

Optional: named connection registry (similar to Sambex) if needed.

```
# iex -S mix

u   = "smb://127.0.0.1/private"
usr = "example2"
pwd = "badpass"

# 0) (optional) pool
:ok = Rumbex.connect(u, usr, pwd, size: 4)

# 1) handler
defmodule Demo.Handler do
  def process(%{path: _processing_path, name: _name, size: _size}) do
    # ... your logic ...
    {:ok, :done}
  end
end

# 2) hot folder config
cfg = %Rumbex.HotFolder.Config{
  url: u, username: usr, password: pwd,
  base_path: "/",
  folders: %{incoming: "incoming", processing: "processing", success: "success", errors: "errors"},
  filters: %{name_patterns: [~r/\.txt$/i], exclude_patterns: [~r/^\./], min_size: 1},
  stability: %{checks: 1, interval: 100},
  poll_interval: %{initial: 300, max: 5_000, backoff_factor: 2.0},
  handler: {Demo.Handler, :process, []},
  pool_size: 4,
  on_success: :unique     # <— MWP: unique names instead of delete/overwrite
}

{:ok, pid} = Rumbex.HotFolder.start_link(cfg)
:ok         = Rumbex.HotFolder.poll_now(pid)

# 3) test
:ok      = Rumbex.mkdir_p(u, usr, pwd, "/incoming")
{:ok, _} = Rumbex.write_file(u, usr, pwd, "/incoming/hello.txt", "hello from rumbex")
Process.sleep(1500)

Rumbex.list_dir(u, usr, pwd, "/success")
# ⇒ you will see hello.txt (or hello-<timestamp>.txt, if name is already taken)

Rumbex.list_dir(u, usr, pwd, "/processing")
# ⇒ shoul be empty

```

API
```
{:ok, pid} = Rumbex.HotFolder.start_link(config)
:ok         = Rumbex.HotFolder.poll_now(pid)   # force immediate polling
:Rumbex.HotFolder.status(pid)                  # :polling | {:processing, name} | :error | :starting
:Rumbex.HotFolder.stats(pid)                   # %{files_processed, files_failed, last_poll, current_interval, uptime}
:Rumbex.HotFolder.stop(pid)                    # stop
```
---

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

