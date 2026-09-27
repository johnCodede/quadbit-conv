`default_nettype none

// pe_quadbit.v — Quadbit Processing Element (PE)
//
// Weight encoding (2 wires, "quadbit" / dualnary):
//   2'b10 -> +1    pass  +x
//   2'b00 ->  0    pass   0  (native zero-skip)
//   2'b01 -> -1    pass  -x
//   2'b11 -> CTRL  pass   0  + raise ctrl_flag (host-selectable semantics:
//                            error / interrupt / skip)
//
// Datapath is a pure sign-select (2:1 mux tree) + negate. No multiplier.
// Fully combinational => single-cycle.
//
// Output width is IN_W+1 bits signed so that both +255 and -255 are
// representable (8-bit unsigned activations 0..255).

module pe_quadbit #(
  parameter IN_W  = 8,            // activation width (unsigned)
  parameter OUT_W = IN_W + 1      // signed result width
) (
  input  wire [1:0]       w,        // quadbit weight code
  input  wire [IN_W-1:0]  x,        // activation (unsigned 0..2^IN_W-1)
  output wire [OUT_W-1:0] out,      // signed: +x, 0, or -x
  output wire             ctrl_flag // high iff w == 2'b11
);

  wire [OUT_W-1:0] pos = {1'b0, x};
  wire [OUT_W-1:0] neg = -pos;

  assign out       = (w == 2'b10) ? pos :
                     (w == 2'b01) ? neg : {OUT_W{1'b0}};
  assign ctrl_flag = (w == 2'b11);

endmodule
