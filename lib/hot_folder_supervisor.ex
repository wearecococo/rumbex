defmodule Rumbex.HotFolderSupervisor do
  @moduledoc """
  Dynamic supervisor for multiple `Rumbex.HotFolder` processes.
  """
  use DynamicSupervisor

  def start_link(opts),
    do: DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a hot folder child.
  """
  def start_hot_folder(sup \\ __MODULE__, cfg, opts \\ []) do
    spec = %{
      id: {Rumbex.HotFolder, make_ref()},
      start: {Rumbex.HotFolder, :start_link, [cfg, opts]},
      restart: :permanent,
      shutdown: 30_000,
      type: :worker
    }

    DynamicSupervisor.start_child(sup, spec)
  end
end
