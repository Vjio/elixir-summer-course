defmodule School.State do
  use GenServer

  alias School.Player
  alias School.Logic

  @max_active_rules 5
  @available_rules [
    :rule1,
    :rule2,
    :rule3,
    :rule4,
    :rule5,
    :rule6,
    :rule7,
    :rule8,
    :rule9,
    :rule10
  ]
  @max_game_time_seconds 200

  defstruct active_rules: [],
            players: [],
            current_game_time: 0

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  def add_packet_to_player_queue(name, package) do
    GenServer.call(__MODULE__, {:add_packet_to_player_queue, name, package})
  end

  def remove_packet_from_player_queue(name) do
    GenServer.call(__MODULE__, {:remove_packet_from_player_queue, name})
  end

  def get_player_queue(name) do
    GenServer.call(__MODULE__, {:get_player_queue, name})
  end

  def add_player(name, pid) do
    GenServer.call(__MODULE__, {:add_player, name, pid})
  end

  def player_ready(name) do
    GenServer.call(__MODULE__, {:player_ready, name})
  end

  def set_random_rule do
    GenServer.cast(__MODULE__, :set_random_rule)
  end

  def get_active_rules do
    GenServer.call(__MODULE__, :get_active_rules)
  end

  def update_player_score(pid, package, expected) do
    GenServer.call(__MODULE__, {:update_player_score, pid, package, expected})
  end

  def reset_player(name) do
    GenServer.call(__MODULE__, {:reset_player, name})
  end

  @impl true
  def handle_call({:add_packet_to_player_queue, name, package}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)
    updated_queue = player.queue ++ [package]
    updated_player = Map.put(player, :queue, updated_queue)
    updated_player_list = [updated_player | remaining_players]

    {:reply, {updated_player, updated_player_list}, state}
  end

  @impl true
  def handle_call({:get_player_queue, name}, _from, state) do
    {[player], _remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)

    {:reply, player.queue, state}
  end

  @impl true
  def handle_call({:remove_packet_from_player_queue, name}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)

    new_queue = tl(player.queue)
    updated_player = Map.put(player, :queue, new_queue)
    updated_player_list = [updated_player | remaining_players]

    {:reply, {updated_player, updated_player_list}, state}
  end

  @impl true
  def handle_call({:reset_player, name}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)

    updated_player = Map.put(player, :ready?, false)
    updated_player_list = [updated_player | remaining_players]
    game_state = maybe_start_game(updated_player_list, state)

    new_state =
      state
      |> Map.put(:players, updated_player_list)
      |> Map.put(:game_state, game_state)
      |> Map.put(:current_game_time, 0)
      |> Map.put(:active_rules, [])

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, sort_by_score(updated_player_list)}
    )

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      :update_rules
    )

    {:reply, {updated_player, game_state}, new_state}
  end

  @impl true
  def handle_call({:player_ready, name}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)

    readied_player = Map.put(player, :ready?, true)
    updated_player_list = [readied_player | remaining_players]
    game_state = maybe_start_game(updated_player_list, state)

    new_state =
      state
      |> Map.put(:players, updated_player_list)
      |> Map.put(:game_state, game_state)

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, sort_by_score(updated_player_list)}
    )

    {:reply, {readied_player, game_state}, new_state}
  end

  @impl true
  def handle_call(:get_active_rules, _from, state) do
    {:reply, state.active_rules, state}
  end

  @impl true
  def handle_call({:update_player_score, name, package, expected}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)

    {validation_result, validation_msg} =
      Logic.validate(package, state.active_rules)

    decision =
      if validation_result == expected,
        do: :correct,
        else: :incorrect

    new_combo =
      if decision == :correct do
        Map.get(player, :combo, 0) + 1
      else
        0
      end

    score_delta =
      if decision == :correct,
        do: 1 * new_combo,
        else: -1

    new_score = max(player.score + score_delta, 0)

    updated_player =
      player
      |> Map.put(:score, new_score)
      |> Map.put(:combo, new_combo)

    updated_player_list = [updated_player | remaining_players]

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, sort_by_score(updated_player_list)}
    )

    new_state = Map.put(state, :players, updated_player_list)

    {:reply, {updated_player, decision, validation_msg}, new_state}
  end

  @impl true
  def handle_call({:add_player, name, pid}, _from, state) do
    Process.monitor(pid)

    new_player = %Player{
      pid: pid,
      name: name
    }

    updated_player_list = [new_player | state.players]
    new_state = Map.put(state, :players, updated_player_list)

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, updated_player_list}
    )

    {:reply, new_player, new_state}
  end

  @impl true
  def handle_cast(:set_random_rule, state) do
    new_state = maybe_activate_random_rule(state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    # capture last tick after game has ended
    if state.game_state == :waiting do
      {:noreply, state}
    else
    Process.send_after(self(), :tick, 1_000)

    current_game_time = state.current_game_time

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:tick_update, current_game_time}
    )

    state_with_new_rule =
      if rem(current_game_time, 30) == 0 do
        Phoenix.PubSub.broadcast(
          School.PubSub,
          "game_room",
          :update_rules
        )

        maybe_activate_random_rule(state)
      else
        state
      end

    state_after_time_check =
      if current_game_time > @max_game_time_seconds do
        Phoenix.PubSub.broadcast(
          School.PubSub,
          "game_room",
          {:game_ended, :ended}
        )
        Map.put(state_with_new_rule, :game_state, :ended)
      else
        state_with_new_rule
      end

    new_state =
      Map.put(state_after_time_check, :current_game_time, current_game_time + 1)

    {:noreply, new_state}
    end
  end

  # handle killed PID
  # {:DOWN, #Reference<0.4092222473.1123811329.133049>, :process, #PID<0.664.0>, {:shutdown, :closed}}
  @impl true
  def handle_info({:DOWN, _, _, pid, _}, state) do
    player_list = state.players
    updated_player_list = Enum.reject(player_list, fn player -> player.pid == pid end)
    new_state = Map.put(state, :players, updated_player_list)

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, updated_player_list}
    )

    {:noreply, new_state}
  end

  def max_game_time do
    @max_game_time_seconds
  end

  defp maybe_activate_random_rule(state) do
    if length(state.active_rules) < @max_active_rules do
      activate_new_rule(state)
    else
      state
    end
  end

  defp activate_new_rule(state) do
    active_rules = state.active_rules

    new_rule =
      @available_rules
      |> Enum.reject(fn rule -> rule in active_rules end)
      |> Enum.random()

    new_state =
      Map.put(state, :active_rules, [new_rule | active_rules])

    new_state
  end

  defp sort_by_score(player_list) do
    Enum.sort(player_list, fn p1, p2 -> p1.score > p2.score end)
  end

  defp maybe_start_game(player_list, state) do
    all_ready? = Enum.all?(player_list, fn player -> player.ready? end)

    if all_ready? do
      Phoenix.PubSub.broadcast(
        School.PubSub,
        "game_room",
        {:game_start, :in_progress}
      )

      Process.send_after(self(), :tick, 1_000)

      :in_progress
    else
      # announce players that game has been reset
      if state.game_state == :ended do
      Phoenix.PubSub.broadcast(
        School.PubSub,
        "game_room",
        {:game_reset, :waiting}
      )
      end
      :waiting
    end
  end
end
