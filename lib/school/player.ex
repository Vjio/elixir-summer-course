defmodule School.Player do
  @type t :: %__MODULE__{
          name: String.t(),
          score: integer(),
          combo: integer(),
          pid: pid(),
          ready?: boolean(),
          queue: list(School.Package.t())
        }

  defstruct name: nil,
            score: 0,
            combo: 0,
            pid: nil,
            ready?: false,
            queue: []
end
