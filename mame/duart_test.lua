-- Register-level exercise of the MC68681 through the 68010's address space,
-- for comparing MAME's model with rtl/duart/mc68681.sv (sim/tb_duart.sv).
-- Steps run at frame boundaries from RD_DUART_T0 (default 2.5 s, after the
-- game has initialised the chip and left it alone); every read is logged as
-- "t reg value" to RD_DUART_LOG, and writes as "t reg = value", so the
-- testbench can replay the same sequence with the same spacing and compare.
-- Local loopback mode keeps the test inside the chip.  IMR is cleared first
-- so the game's level-6 handler does not consume the loopback bytes.
local mach = manager.machine
local sp   = mach.devices[":mainpcb:maincpu"].spaces["program"]
local f    = io.open(os.getenv("RD_DUART_LOG") or "duart_test.log", "w")
local t0   = tonumber(os.getenv("RD_DUART_T0") or "2.5")
local function w(reg, v)  sp:write_u16(0xff0000 + reg * 2, v << 8); f:write(string.format("%.6f %d = %02x\n", mach.time:as_double(), reg, v)) end
local function r(reg)     local v = (sp:read_u16(0xff0000 + reg * 2) >> 8) & 0xff; f:write(string.format("%.6f %d %02x\n", mach.time:as_double(), reg, v)); return v end
-- each step is a list of actions executed within one frame
local steps = {
  function () w(5, 0x00); r(1); r(9); r(5); r(12); r(13) end,          -- quiet, read SRA/SRB/ISR/IVR/IP
  function () w(2, 0x10); w(0, 0x93); w(0, 0x87); w(1, 0xcc); w(2, 0x05) end,  -- A: 8N1 local loopback, 38400, enable
  function () r(1); r(0); r(0) end,                                      -- SRA, MR1A, MR2A
  function () w(3, 0x55) end,                                            -- send one byte
  function () r(1); r(5) end,                                            -- after a frame: RxRDY, TxEMT; ISR
  function () r(3); r(1) end,                                            -- RHRA = 55, status after pop
  function () w(3, 0x01); w(3, 0x02); w(3, 0x03); w(3, 0x04) end,       -- four bytes back to back (second overwrites? no: THR buffered when busy)
  function () r(1); r(3); r(1); r(3); r(1); r(3); r(1); r(3); r(1) end,  -- drain FIFO with status between
  function () w(2, 0x60); w(2, 0x70); r(1); r(5); r(3); r(1); w(2, 0x50); r(5) end,  -- break start/stop in loopback
  function () w(2, 0x10); w(8, 0x1b); w(8, 0x87); w(9, 0xcc); w(10, 0x05); w(11, 0xa5) end,  -- B: 8 bits, even parity, loopback
  function () r(9); r(11); r(9); w(10, 0x20) end,                        -- SRB, RHRB, then reset receiver B
  function () w(6, 0x00); w(7, 0x40); w(4, 0x30); r(14); end,            -- counter mode X1/16, preload 0x40, start
  function () r(6); r(7); r(5) end,                                      -- CUR/CLR/ISR (counter ready expected)
  function () r(15); r(5); w(4, 0x70); r(14) end,                        -- stop; timer mode X1/16
  function () r(5); r(15); r(5) end,                                     -- timer: ISR set, stop clears
  function () w(13, 0x00); w(14, 0x03); r(13); w(15, 0x01); r(4) end,    -- output port set/reset, IP, IPCR
  function () w(2, 0x30); r(1); w(2, 0x05); r(1); w(3, 0x7e); r(1) end,  -- tx reset, re-enable, send
  function () r(1); r(3); r(1) end,
}
local step, started = 1, false
_G.duart_test_fn = emu.add_machine_frame_notifier(function ()
  local t = mach.time:as_double()
  if t < t0 then return end
  if steps[step] then
    f:write(string.format("# step %d\n", step))
    steps[step](); f:flush()
    step = step + 1
  end
end)
