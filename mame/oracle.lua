-- oracle.lua: MAME-side trace capture for the Race Drivin' FPGA core.
--
-- Run with any of the harddriv-family machines, e.g.
--
--   RD_LOG=run1 mame racedriv -autoboot_script mame/oracle.lua ...
--
-- Writes one or more text logs under $RD_LOG.* (default "oracle"). Which
-- streams are captured is chosen with environment variables, all optional:
--
--   RD_LOG=<prefix>     output file prefix (default oracle)
--   RD_ASIC65=1         68010 <-> ASIC65 traffic: command, parameters, results
--   RD_DSK=1            DSK control latch writes and DSP32 PIO register traffic
--   RD_DUART=1          68681 register writes (upper byte lane) and reads
--   RD_OUT=1            output latches: wheel force byte, coin counters, lamps, ZP, resets
--   RD_PHYS=1           per-frame dump of the DSK RAM physics block and input block
--   RD_HASH=<n>         CRC of the screen every n frames (slow in Lua; 60 is sensible)
--   RD_TRACE68K=1       68010 instruction trace through the debugger (needs -debug)
--
-- Every line starts with the frame number and the emulated time so logs from
-- different runs and from the FPGA can be aligned. Addresses are 68010 byte
-- addresses. See NOTES.md section 3 for what each register is.

local mach = manager.machine
local cpu  = mach.devices[":mainpcb:maincpu"]
local sp   = cpu.spaces["program"]
local env  = os.getenv

local prefix = env("RD_LOG") or "oracle"
local frame = 0
local logs = {}

local function openlog(name)
  local f = assert(io.open(prefix .. "." .. name .. ".log", "w"))
  f:write(string.format("# %s %s\n", name, mach.system.name))
  logs[#logs + 1] = f
  return f
end

local function stamp()
  return string.format("%d %.6f ", frame, mach.time:as_double())
end

-- keep tap objects alive; MAME removes a tap when its handle is collected
local taps = {}

local function wtap(first, last, name, fn)
  taps[#taps + 1] = sp:install_write_tap(first, last, name, fn)
end
local function rtap(first, last, name, fn)
  taps[#taps + 1] = sp:install_read_tap(first, last, name, fn)
end

---------------------------------------------------------------------------
-- ASIC65: 0x914000 even word = parameter, odd word = command; reads = result;
-- 0x918000 = io_r status.
if env("RD_ASIC65") == "1" then
  local f = openlog("asic65")
  wtap(0x914000, 0x917fff, "asic65_w", function(offset, data, mask)
    local kind = ((offset & 2) == 0) and "param" or "cmd"
    f:write(stamp(), string.format("%s %04x\n", kind, (data >> 8 * ((offset & 1))) & 0xffff))
  end)
  rtap(0x914000, 0x917fff, "asic65_r", function(offset, data, mask)
    f:write(stamp(), string.format("result %04x\n", data & 0xffff))
  end)
  rtap(0x918000, 0x91bfff, "asic65_io_r", function(offset, data, mask)
    f:write(stamp(), string.format("io %04x\n", data & 0xffff))
  end)
end

---------------------------------------------------------------------------
-- DSK board: control latch 0x85C800-0x85C81F (function = (offset>>1)&7,
-- value = (offset>>4)&1), DSP32 PIO window 0x85C000-0x85C7FF.
if env("RD_DSK") == "1" then
  local f = openlog("dsk")
  wtap(0x85c800, 0x85c81f, "dsk_ctl_w", function(offset, data, mask)
    f:write(stamp(), string.format("ctl fn=%d val=%d\n", (offset >> 1) & 7, (offset >> 4) & 1))
  end)
  wtap(0x85c000, 0x85c7ff, "dsk_pio_w", function(offset, data, mask)
    f:write(stamp(), string.format("piow reg=%d data=%04x\n", (offset >> 1) & 0x3ff, data & 0xffff))
  end)
  rtap(0x85c000, 0x85c7ff, "dsk_pio_r", function(offset, data, mask)
    f:write(stamp(), string.format("pior reg=%d data=%04x\n", (offset >> 1) & 0x3ff, data & 0xffff))
  end)
end

---------------------------------------------------------------------------
-- 68681 DUART at 0xFF0000-0xFF001F, registers on the upper byte lane.
if env("RD_DUART") == "1" then
  local f = openlog("duart")
  wtap(0xff0000, 0xff001f, "duart_w", function(offset, data, mask)
    f:write(stamp(), string.format("w reg=%d data=%02x\n", (offset >> 1) & 15, (data >> 8) & 0xff))
  end)
  rtap(0xff0000, 0xff001f, "duart_r", function(offset, data, mask)
    f:write(stamp(), string.format("r reg=%d data=%02x\n", (offset >> 1) & 15, (data >> 8) & 0xff))
  end)
end

---------------------------------------------------------------------------
-- Output latches.
if env("RD_OUT") == "1" then
  local f = openlog("out")
  -- wr2: steering wheel force byte (data >> 8)
  wtap(0xb00000, 0xb7ffff, "wr2_w", function(offset, data, mask)
    if offset == 0xb00000 then
      f:write(stamp(), string.format("force %02x\n", (data >> 8) & 0xff))
    end
  end)
  -- wr0: SEL1-4 (1..4), coin counters (6, 7)
  wtap(0xa00000, 0xa7ffff, "wr0_w", function(offset, data, mask)
    f:write(stamp(), string.format("wr0 fn=%d val=%d\n", (offset >> 1) & 7, (offset >> 4) & 1))
  end)
  -- wr1: shifter interface latch (data >> 8)
  wtap(0xa80000, 0xafffff, "wr1_w", function(offset, data, mask)
    f:write(stamp(), string.format("wr1 %02x\n", (data >> 8) & 0xff))
  end)
  -- nwr: CR2/CR1, LC1/LC2 lamps, ZP1/ZP2, /GSPRES, /MSPRES
  wtap(0x604000, 0x607fff, "nwr_w", function(offset, data, mask)
    f:write(stamp(), string.format("nwr fn=%d val=%d\n", (offset >> 1) & 7, (offset >> 4) & 1))
  end)
end

---------------------------------------------------------------------------
-- Per-frame physics and input snapshot from DSK RAM (NOTES.md section 1):
-- results block at 0x900C70 (current segment at +0x58), inputs at
-- 0x900D28 wheel, 0x900D2A brake, 0x900D2C clutch, 0x900D32 throttle,
-- 0x900D38 key. Dumps 0x900C70-0x900D5F as words.
local phys
if env("RD_PHYS") == "1" then
  phys = openlog("phys")
  phys:write("# frame time words[0x900C70..0x900D5E]\n")
end

---------------------------------------------------------------------------
-- Screen CRC every n frames.
local hash_every = tonumber(env("RD_HASH") or "0") or 0
local hashlog
local screen
if hash_every > 0 then
  hashlog = openlog("hash")
  for tag, s in pairs(mach.screens) do screen = s break end
end

local function crc32(s)
  -- small table-free CRC32, fine for a few frames per second
  local crc = 0xffffffff
  for i = 1, #s do
    crc = crc ~ s:byte(i)
    for _ = 1, 8 do
      local m = -(crc & 1)
      crc = (crc >> 1) ~ (0xedb88320 & m)
    end
  end
  return (~crc) & 0xffffffff
end

---------------------------------------------------------------------------
-- 68010 instruction trace via the debugger (requires -debug on the command line).
if env("RD_TRACE68K") == "1" then
  local dbg = mach.debugger
  if dbg then
    dbg:command(string.format("trace %s.trace68k.log,mainpcb:maincpu,noloop", prefix))
    dbg:command("go")
  else
    print("[oracle] RD_TRACE68K needs -debug (and -debugger none for headless use)")
  end
end

---------------------------------------------------------------------------
emu.register_frame_done(function()
  frame = frame + 1
  if phys then
    local words = {}
    for a = 0x900c70, 0x900d5e, 2 do
      words[#words + 1] = string.format("%04x", sp:read_u16(a))
    end
    phys:write(stamp(), table.concat(words, " "), "\n")
  end
  if hashlog and screen and frame % hash_every == 0 then
    hashlog:write(stamp(), string.format("%08x\n", crc32(screen:pixels())))
  end
end)

emu.register_stop(function()
  for _, f in ipairs(logs) do f:close() end
end)

print(string.format("[oracle] logging to %s.*.log", prefix))
