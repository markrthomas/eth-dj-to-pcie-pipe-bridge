#!/usr/bin/env python3
"""lp/oss/power.py — switching-activity power estimate with OpenSTA (the pip `openroad` wheel).

  power.py --lib nangate.lib --netlist bridge_gl.v --vcd gls.vcd [--scope TOP/eth_dj_pipe7_bridge]
           [--pclk-ns 2.0] [--eth-ns 5.0] --out report.json

Reads the Yosys/Nangate45 gate netlist and the gate-level-simulation VCD, runs report_power for the
whole design and for every first-level instance (the power-domain split of lp/bridge.upf: PD_DP =
datapath instances, PD_AON = the rest), and writes the numbers as JSON.  ESTIMATE ONLY: no placement,
no parasitics, no clock tree, typical corner, Nangate45 (45 nm) - useful for comparing options and
for the order of magnitude, not as sign-off numbers.
"""
import argparse, json, os, re, sys, tempfile

PD_DP = ["u_tx_gate", "u_tx_cdc", "u_tx_framer", "u_tx_egress",
         "u_rx_ingress", "u_rx_deframer", "u_rx_cdc", "u_eth_egress"]


def parse_total(text):
    """Return {internal, switching, leakage, total} in watts from an OpenSTA report_power table."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"\s*Total\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)", line)
        if m:
            out = dict(internal=float(m.group(1)), switching=float(m.group(2)),
                       leakage=float(m.group(3)), total=float(m.group(4)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--netlist", required=True)
    ap.add_argument("--vcd", required=True)
    ap.add_argument("--top", default="eth_dj_pipe7_bridge")
    ap.add_argument("--scope", default="TOP/eth_dj_pipe7_bridge", help="VCD scope of the DUT")
    ap.add_argument("--pclk-ns", type=float, default=2.0)
    ap.add_argument("--eth-ns", type=float, default=5.0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    from openroad import Tech, Design
    tech = Tech()
    tech.readLiberty(os.path.abspath(a.lib))
    d = Design(tech)
    tmp = tempfile.mkdtemp()

    def tcl(cmd):
        return d.evalTclString(cmd)

    tcl(f"read_verilog {os.path.abspath(a.netlist)}")
    tcl(f"link_design {a.top}")
    tcl(f"create_clock -name pclk -period {a.pclk_ns} [get_ports pclk]")
    tcl(f"create_clock -name eth_clk -period {a.eth_ns} [get_ports eth_clk]")
    tcl(f"read_vcd -scope {a.scope} {os.path.abspath(a.vcd)}")

    def report(extra, name):
        f = os.path.join(tmp, name + ".rpt")
        tcl(f"report_power {extra} > {f}")
        return open(f).read()

    res = {"clocks": {"pclk_ns": a.pclk_ns, "eth_clk_ns": a.eth_ns}, "vcd": os.path.basename(a.vcd)}
    whole = report("-digits 6", "total")
    res["design_report"] = whole
    res["design_W"] = parse_total(whole)
    inst = {}
    for u in PD_DP + ["u_ctrl", "u_msgbus", "u_msgbus_tgt", "u_rf", "u_fc"]:
        try:
            inst[u] = parse_total(report(f"-instances [get_cells {u}] -digits 6", u))
        except Exception as e:                       # instance absent / flattened away
            inst[u] = {"error": str(e)[:80]}
    res["instances_W"] = inst
    json.dump(res, open(a.out, "w"), indent=1)
    t = res["design_W"].get("total")
    print("design total: %s" % ("%.3f mW" % (t * 1e3) if t is not None else "n/a"))


if __name__ == "__main__":
    sys.exit(main())
