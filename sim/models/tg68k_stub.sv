// Lint-only stub; the real TG68K is VHDL and is converted with GHDL for simulation.
module TG68KdotC_Kernel #(parameter SR_Read=0, VBR_Stackframe=0, extAddr_Mode=0, MUL_Mode=0, DIV_Mode=0, BitField=0, BarrelShifter=0, MUL_Hardware=0) (
  input clk, nReset, clkena_in, input [15:0] data_in, input [2:0] IPL, input IPL_autovector, berr, input [1:0] CPU,
  output [31:0] addr_out, output [15:0] data_write, output nWr, output nUDS, nLDS, output [1:0] busstate, output longword, output nResetOut, output [2:0] FC, output clr_berr, output skipFetch, output [31:0] regin_out, output [3:0] CACR_out, output [31:0] VBR_out);
endmodule
