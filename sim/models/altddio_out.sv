// Simulation model of Altera's altddio_out as used for the SDRAM clock pin:
// the output takes datain_h after the rising edge of outclock and datain_l
// after the falling edge.
module altddio_out #(
  parameter extend_oe_disable = "OFF",
  parameter intended_device_family = "Cyclone V",
  parameter invert_output = "OFF",
  parameter lpm_hint = "UNUSED",
  parameter lpm_type = "altddio_out",
  parameter oe_reg = "UNREGISTERED",
  parameter power_up_high = "OFF",
  parameter width = 1
) (
  input  logic [width-1:0] datain_h,
  input  logic [width-1:0] datain_l,
  input  logic             outclock,
  output logic [width-1:0] dataout,
  input  logic             aclr,
  input  logic             aset,
  input  logic             oe,
  input  logic             outclocken,
  input  logic             sclr,
  input  logic             sset
);
  always @(posedge outclock) dataout <= datain_h;
  always @(negedge outclock) dataout <= datain_l;
endmodule
