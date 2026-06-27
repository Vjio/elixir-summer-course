defmodule School.Player do
  @type t :: %__MODULE__{
          name: String.t(),
          score: integer(),
          combo: integer(),
          pid: pid(),
          ready?: boolean()
        }

  defstruct name: nil,
            score: 0,
            combo: 0,
            pid: nil,
            ready?: false
end
