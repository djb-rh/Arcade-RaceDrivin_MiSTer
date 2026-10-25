-- Replay a cabinet input script (tools/inputscript.py) into the cockpit
-- set's ports, at frame boundaries: RD_INPUTS=<file>.  Each applied event is
-- echoed with the port value the 68010 then reads, so the script's values
-- can be checked against what MAME really presents.  RD_INPUTS_ORACLE=1
-- also loads oracle.lua (path in RD_INPUTS_ORACLE_PATH).
local mach = manager.machine
local ports = mach.ioport.ports
local function field_of(ptag, fname)
  local p = ports[ptag]
  if not p then print("[inputs] no port " .. ptag); return nil end
  if fname then
    local f = p.fields[fname]
    if f then return f end
  end
  for _, f in pairs(p.fields) do return f end   -- unnamed IPT_CUSTOM: the only field
end
local map = {
  coin1   = { field_of(":mainpcb:IN0", "Coin 1") },
  coin2   = { field_of(":mainpcb:IN0", "Coin 2") },
  service = { field_of(":mainpcb:IN0", "Service Mode") },
  key     = { field_of(":mainpcb:a80000", "Key") },
  abort   = { field_of(":mainpcb:a80000", "Abort") },
  auxcoin = { field_of(":mainpcb:a80000", "Coin 3") },
  gas     = { field_of(":mainpcb:8BADC.0", "Gas Pedal"), analog = true },
  clutch  = { field_of(":mainpcb:8BADC.1", "Clutch Pedal"), analog = true },
  seat    = { field_of(":mainpcb:8BADC.2"), analog = true },
  shy     = { field_of(":mainpcb:8BADC.3", "Shifter Lever Y"), analog = true },
  shx     = { field_of(":mainpcb:8BADC.4", "Shifter Lever X"), analog = true },
  wheel   = { field_of(":mainpcb:12BADC.0", "Steering Wheel"), analog = true,
              copy = field_of(":mainpcb:8BADC.5", "Wheel") },
  brake   = { field_of(":mainpcb:12BADC.1", "Brake Pedal"), analog = true, reverse = true },
}
-- the cockpit's 8-bit wheel copy, as rtl/harddrivin_main_bus.sv derives it
local function wheel8(w)
  if w <= 0x10 then return 0x10 elseif w >= 0xff0 then return 0xf0 end
  return 0x10 + math.floor((w - 0x10) * 224 / 4064)
end
local events = {}
for line in io.lines(os.getenv("RD_INPUTS") or "inputs.txt") do
  if line:sub(1, 1) ~= "#" and line:match("%S") then
    local t, name, v = line:match("^(%S+)%s+(%S+)%s+(%S+)")
    events[#events + 1] = { tonumber(t), name, tonumber(v) }
  end
end
table.sort(events, function (a, b) return a[1] < b[1] end)
print(string.format("[inputs] %d events", #events))
local next_ev = 1
local pending = {}
if os.getenv("RD_INPUTS_ORACLE") == "1" then dofile(os.getenv("RD_INPUTS_ORACLE_PATH") or "mame/oracle.lua") end
_G.inputs_fn = emu.add_machine_frame_notifier(function ()
  local t = mach.time:as_double()
  while events[next_ev] and t >= events[next_ev][1] do
    local e = events[next_ev]; next_ev = next_ev + 1
    local m = map[e[2]]
    if not m or not m[1] then print("[inputs] unknown control " .. e[2])
    else
      local f = m[1]
      if m.analog then
        f:set_value(m.reverse and (0xfff - e[3]) or e[3])
        if m.copy then m.copy:set_value(wheel8(e[3])) end
      else
        if e[3] ~= 0 then f:set_value(1) else f:clear_value() end
      end
      -- a programmatic value takes effect at the next frame update, so report
      -- the port a frame later
      pending[#pending + 1] = { t, e[2], e[3], f.port }
    end
  end
  if #pending > 0 and (not pending[1][5]) then
    for _, p in ipairs(pending) do p[5] = true end
  else
    for _, p in ipairs(pending) do
      print(string.format("[inputs] t=%.4f %s %d -> port %s reads %04x", p[1], p[2], p[3], p[4].tag, p[4]:read()))
    end
    pending = {}
  end
end)
