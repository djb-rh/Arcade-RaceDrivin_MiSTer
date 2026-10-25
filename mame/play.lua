-- Drive Race Drivin' (cockpit) through a game with scripted inputs, so that
-- the DSP32C runs its real-time physics: coin, Key to start, defaults on
-- the selection screens, then full throttle in first gear with a gentle
-- steering weave. Timeline in seconds of machine time; override the start
-- with RD_PLAY_T0 (default 9). Use with -autoboot_script; combine with
-- oracle.lua by loading it from here (RD_PLAY_ORACLE=1).
local mach = manager.machine
local t0 = tonumber(os.getenv("RD_PLAY_T0") or "9")
local ports = mach.ioport.ports
local function field(ptag, fname)
  local p = ports[ptag]
  if not p then print("[play] no port " .. ptag); return nil end
  local f = p.fields[fname]
  if not f then print("[play] no field " .. fname .. " on " .. ptag); return nil end
  return f
end
local coin  = field(":mainpcb:IN0", "Coin 1")
local key   = field(":mainpcb:a80000", "Key")
local gas   = field(":mainpcb:8BADC.0", "Gas Pedal")
local shx   = field(":mainpcb:8BADC.4", "Shifter Lever X")
local shy   = field(":mainpcb:8BADC.3", "Shifter Lever Y")
local wheel = field(":mainpcb:12BADC.0", "Steering Wheel")

-- (time, action) steps; presses last 0.4 s
local steps = {
  { t0 + 0.0, function () coin:set_value(1) end,  "coin" },
  { t0 + 0.4, function () coin:clear_value() end },
  { t0 + 2.0, function () key:set_value(1) end,   "key (start)" },
  { t0 + 2.4, function () key:clear_value() end },
  { t0 + 4.5, function () key:set_value(1) end,   "key (track)" },
  { t0 + 4.9, function () key:clear_value() end },
  { t0 + 7.0, function () key:set_value(1) end,   "key (transmission)" },
  { t0 + 7.4, function () key:clear_value() end },
  { t0 + 8.0, function () shx:set_value(0x20); shy:set_value(0x20); gas:set_value(0xff) end, "first gear, full throttle" },
}
local next_step = 1
local driving = false
local started = false
if os.getenv("RD_PLAY_ORACLE") == "1" then dofile((os.getenv("RD_PLAY_ORACLE_PATH") or "mame/oracle.lua")) end
_G.play_fn = emu.add_machine_frame_notifier(function ()
  local t = mach.time:as_double()
  while steps[next_step] and t >= steps[next_step][1] do
    steps[next_step][2]()
    if steps[next_step][3] then print(string.format("[play] t=%.1f %s", t, steps[next_step][3])) end
    next_step = next_step + 1
  end
  if next_step > #steps then
    -- weave the wheel +-0x180 around centre with a 4 s period
    wheel:set_value(0x800 + math.floor(0x180 * math.sin(t * 2 * math.pi / 4)))
  end
end)
