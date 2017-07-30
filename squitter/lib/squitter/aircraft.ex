defmodule Squitter.Aircraft do
  use GenServer
  use Squitter.Messages

  require Logger
  use Bitwise
  import Squitter.Utils.Math

  alias Squitter.Decoding.ExtSquitter.{GroundSpeed, AirSpeed}

  @timeout_period_s   60
  @age_cycle_s        1

  def start_link(address) do
    GenServer.start_link(__MODULE__, [address], name: {:via, Registry, {Squitter.AircraftRegistry, address}})
  end

  def init([address]) do
    :pg2.join(:aircraft, self())

    schedule_next_age_cycle()

    {:ok, %{
      address: address,
      msgs: 0,
      aircraft_cat: :unknown,
      altitude: nil,
      callsign: "",
      lat: nil,
      lon: nil,
      even_pos: nil,
      odd_pos: nil,
      velocity_kt: nil,
      airspeed_type: nil,
      heading: nil,
      vr: nil,
      vr_dir: nil,
      vr_src: nil,
      position_history: [],
      timeout_enabled: true,
      last_received: System.monotonic_time(:seconds),
      age: 0}}
  end

  def handle_cast({:dispatch, msg}, state) do
    {:ok, new_state} = handle_msg(msg, state)
    {:noreply, set_received(new_state)}
  end

  def handle_cast(:enable_age_timeout, state) do
    {:noreply, %{state | timeout_enabled: true}}
  end

  def handle_cast(:disable_age_timeout, state) do
    {:noreply, %{state | timeout_enabled: false}}
  end

  def handle_call(:report, _from, state) do
    reply = state
            |> Map.take([
              :callsign,
              :msgs,
              :aircraft_cat,
              :altitude,
              :velocity_kt,
              :heading,
              :vr,
              :vr_dir,
              :address,
              :age])
            |> Map.put(:position, {state.lat, state.lon})

    {:reply, {:ok, reply}, state}
  end

  defp handle_msg(%{crc: :invalid}, state) do
    Logger.warn "Ignoring message with invalid CRC"
    {:ok, state}
  end

  defp handle_msg(%{tc: {:aircraft_id, _}, type_msg: %{aircraft_cat: cat, callsign: callsign}}, state) do
    {:ok, %{state | aircraft_cat: cat, callsign: callsign}}
  end

  # position with even flag
  defp handle_msg(%{tc: {:airborne_pos_baro_alt, _}, type_msg: %{flag: flag} = pos}, state) when band(flag, 1) == 0 do
    calculate_lat_lon(%{state | altitude: pos.alt, even_pos: pos})
  end

  # position with odd flag
  defp handle_msg(%{tc: {:airborne_pos_baro_alt, _}, type_msg: %{flag: flag} = pos}, state) when band(flag, 1) == 1 do
    calculate_lat_lon(%{state | altitude: pos.alt, odd_pos: pos})
  end

  defp handle_msg(%{tc: :air_velocity, type_msg: %GroundSpeed{} = gs}, state) do
    {vel, head} = calculate_vector(gs)
    {vr, vrdir, vrsrc} = calculate_vertical_rate(gs)
    {:ok, %{state | velocity_kt: vel, heading: head, vr: vr, vr_dir: vrdir, vr_src: vrsrc}}
  end

  defp handle_msg(%{tc: :air_velocity, type_msg: %AirSpeed{} = msg}, state) do
    heading = if msg.sign_hdg do
      :erlang.float(msg.hdg) / 1024.0 * 360.0
    else
      :na
    end

    as_type = if msg.as_type, do: :true, else: :indicated
    {vr, vrdir, vrsrc} = calculate_vertical_rate(msg)

    {:ok, %{state | airspeed_type: as_type, velocity_kt: msg.as, heading: heading, vr: vr, vr_dir: vrdir, vr_src: vrsrc}}
  end

  defp handle_msg(%{tc: {:airborne_pos_gnss_height, _code}}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%{tc: {:surface_pos, _}}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%AltitudeReply{}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%IdentityReply{}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%AllCallReply{}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%ShortAcas{}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%LongAcas{}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%{tc: :aircraft_op_status, type_msg: _msg}, state) do
    # TODO
    # The Version Number for all 1090 MHz ADS-B Messages originating for each specific
    # ADS-B target is determined from the decoding of the Version Number subfield of the
    # Aircraft Operational Status Message. An ADS-B Version One (1) Receiving Subsystem
    # initially assumes that the messages conform to Version Zero (0) message formats, until or
    # unless received Version Number data indicates otherwise. The Version Number is
    # retained and associated with all messages from that specific target. This Version Number
    # is used for determining the applicable message formats to be applied for the decoding of
    # all 1090 MHz ADS-B Messages received from that target.
    {:ok, state}
  end

  defp handle_msg(%{tc: :target_state_status, type_msg: _msg}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%{tc: :aircraft_status, type_msg: _msg}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(%{tc: :test_message, type_msg: _}, state) do
    # TODO
    {:ok, state}
  end

  defp handle_msg(other, state) do
    Logger.warn "Unhandled msg in #{state.address}: #{inspect other}"
    {:ok, state}
  end

  def calculate_vector(msg) do
    v_we = if msg.sign_ew do
      -1 * (msg.v_ew - 1)
    else
      msg.v_ew - 1
    end

    v_sn = if msg.sign_ns do
      -1 * (msg.v_ns - 1)
    else
      msg.v_ns - 1
    end

    v = :math.sqrt(:math.pow(v_we, 2) + :math.pow(v_sn, 2))
    h = :math.atan2(v_we, v_sn) * (360/(2 * :math.pi))

    h = if h < 0, do: h + 360, else: h

    {Float.round(v, 2), Float.round(h, 2)}
  end

  def calculate_vertical_rate(msg) do
    vr = (msg.vr - 1) * 64
    vr_dir = if msg.sign_vr, do: :down, else: :up
    vrsrc = if msg.vrsrc, do: :geometric, else: :baro
    {vr, vr_dir, vrsrc}
  end

  @cpr_max :math.pow(2, 17)

  @nz 15
  @air_d_lat_even 360.0 / (4 * @nz)
  @air_d_lat_odd  360.0 / (4 * @nz - 1)

  def latitude_index(cpr_even_lat, cpr_odd_lat) do
    floor(59 * cpr_even_lat - 60 * cpr_odd_lat + 0.5)
  end

  def calculate_lat({cpr_lat_even, cpr_lat_odd}) do
    cprlat_even = cpr_lat_even / @cpr_max
    cprlat_odd = cpr_lat_odd / @cpr_max

    j = latitude_index(cprlat_even, cprlat_odd)
    lat_even = @air_d_lat_even * (rem(j, 60) + cprlat_even)
    lat_odd = @air_d_lat_odd * (rem(j, 59) + cprlat_odd)

    lat_even = if lat_even >= 270, do: lat_even - 360, else: lat_even
    lat_odd = if lat_odd >= 270, do: lat_odd - 360, else: lat_odd

    # Northern hemisphere
    lat_even = if lat_even <= 0, do: lat_even + 360, else: lat_even
    lat_odd = if lat_odd <=0, do: lat_odd + 360, else: lat_odd

    {{:even, Float.round(lat_even, 5)}, {:odd, Float.round(lat_odd, 5)}}
  end

  def calculate_lon({parity, lat_val} = lat, {cpr_lon_even, cpr_lon_odd}) do
    cprlon_even = cpr_lon_even / @cpr_max
    cprlon_odd = cpr_lon_odd / @cpr_max

    nll = nl(lat_val)
    ni = max(nll - parity_case(lat, {0, 1}), 1)
    m = floor(cprlon_even * (nll - 1) - cprlon_odd * nll + 0.5)

    lon = (360.0/ni) * (rem(m, ni) + parity_case(lat, {cprlon_even, cprlon_odd}))
    lon = if lon > 180, do: lon - 360, else: lon

    {parity, Float.round(lon, 5)}
  end

  def parity_case({parity, _}, {even_value, odd_value}) do
    case parity do
      :even -> even_value
      :odd -> odd_value
    end
  end

  def calculate_lat_lon(%{even_pos: even, odd_pos: odd} = state) when is_nil(even) or is_nil(odd) do
    {:ok, state}
  end

  def calculate_lat_lon(%{even_pos: even, odd_pos: odd} = state) do
    lat_pair = calculate_lat({even.lat_cpr, odd.lat_cpr})
    {lat_even, lat_odd} = lat_pair

    if in_same_lat_zone?(lat_even, lat_odd) do
      lon_pair = {even.lon_cpr, odd.lon_cpr}

      # Continue computing position
      if even.index > odd.index do
        lon = calculate_lon(lat_even, lon_pair)
        {:ok, %{state | lat: elem(lat_even, 1), lon: elem(lon, 1)}}
      else
        lon = calculate_lon(lat_odd, lon_pair)
        {:ok, %{state | lat: elem(lat_odd, 1), lon: elem(lon, 1)}}
      end
    else
      #Logger.debug "Different latitude zones"
      # Different latitude zones so we can't continue.  Stop and wait for more position messages
      {:ok, state}
    end
  end

  def in_sane_lat_zone?({_, lat1}, {_, lat2}) do
    in_same_lat_zone?(lat1, lat2)
  end
  def in_same_lat_zone?(lat_even, lat_odd) do
    nl(lat_even) == nl(lat_odd)
  end

  def handle_info(:age_cycle, state) do
    new_state = set_age(state)
    if state.timeout_enabled && timeout_expired?(new_state) do
      {:stop, {:shutdown, :timed_out}, new_state}
    else
      schedule_next_age_cycle()
      {:noreply, new_state}
    end
  end

  def terminate({:shutdown, :timed_out}, state) do
    Logger.debug "Aircraft #{state.address} timed out"
  end

  def terminate(reason, state) do
    Logger.debug "Aircraft #{state.address} process terminated due to reason #{inspect reason}"
  end

  # Private helpers

  defp timeout_expired?(%{age: age}) do
    age > @timeout_period_s
  end

  defp set_received(state) do
    %{state | msgs: state.msgs + 1, last_received: System.monotonic_time(:seconds)}
    |> set_age
  end

  defp set_age(%{last_received: last} = state) do
    now = System.monotonic_time(:seconds)
    %{state | age: now - last}
  end

  defp schedule_next_age_cycle do
    Process.send_after(self(), :age_cycle, @age_cycle_s * 1000)
  end

end