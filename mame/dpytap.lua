-- Log the GSP's display-register writes (DPYCTL, DPYSTRT, DPYINT, DPYTAP,
-- DPYADR, blanking registers) with the raster position they land on, so the
-- core's scan-out can be compared with MAME frame by frame.  Prints during
-- the windows given by RD_TAP_WINDOWS (default "50-50.3,62-62.3", seconds of
-- machine time); every first change of a register is printed regardless.
-- Use with -autoboot_script.
local mach = manager.machine
local gsp = mach.devices[":mainpcb:gsp"]
local screen = mach.screens[":mainpcb:screen"]
local mem = gsp.spaces["program"]
local names = {
  [0x000] = "HESYNC", [0x010] = "HEBLNK", [0x020] = "HSBLNK", [0x030] = "HTOTAL",
  [0x040] = "VESYNC", [0x050] = "VEBLNK", [0x060] = "VSBLNK", [0x070] = "VTOTAL",
  [0x080] = "DPYCTL", [0x090] = "DPYSTRT", [0x0a0] = "DPYINT", [0x0b0] = "CONTROL",
  [0x0c0] = "HSTDATA", [0x0d0] = "HSTADRL", [0x0e0] = "HSTADRH", [0x0f0] = "HSTCTLL",
  [0x100] = "HSTCTLH", [0x110] = "INTENB", [0x120] = "INTPEND", [0x130] = "CONVSP",
  [0x140] = "CONVDP", [0x150] = "PSIZE", [0x160] = "PMASK", [0x1b0] = "DPYTAP",
  [0x1c0] = "HCOUNT", [0x1d0] = "VCOUNT", [0x1e0] = "DPYADR", [0x1f0] = "REFCNT",
}
local windows = {}
for a, b in string.gmatch(os.getenv("RD_TAP_WINDOWS") or "50-50.3,62-62.3", "([%d%.]+)%-([%d%.]+)") do
  windows[#windows + 1] = { tonumber(a), tonumber(b) }
end
local last = {}
local function in_window(t)
  for _, w in ipairs(windows) do if t >= w[1] and t <= w[2] then return true end end
  return false
end
-- A tap limited to the I/O register range never fires; tap the whole space
-- and filter.  Offsets are 34010 bit addresses.
_G.dpytap = mem:install_write_tap(0, 0xffffffff, "dpytap", function (offset, data, mask)
  if offset < 0xc0000000 or offset > 0xc00001ff then return end
  local reg = offset & 0x1f0
  local name = names[reg] or string.format("io%03x", reg)
  local t = mach.time:as_double()
  local first = last[reg] ~= data
  if first or in_window(t) then
    print(string.format("[tap] t=%.5f frame=%d v=%3d h=%3d %-7s <= %04x pc=%08x%s",
      t, screen:frame_number(), mem:read_u16(0xc00001d0), 0, name, data, gsp.state["PC"].value,
      first and " (new)" or ""))
  end
  last[reg] = data
end)
_G.dpytap_frame = emu.add_machine_frame_notifier(function ()
  local t = mach.time:as_double()
  if in_window(t) then
    print(string.format("[tap] ---- frame %d done t=%.5f DPYADR=%04x DPYSTRT=%04x DPYINT=%04x DPYCTL=%04x",
      screen:frame_number(), t, mem:read_u16(0xc00001e0), mem:read_u16(0xc0000090),
      mem:read_u16(0xc00000a0), mem:read_u16(0xc0000080)))
  end
end)
