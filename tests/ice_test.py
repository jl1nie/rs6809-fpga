#!/usr/bin/env python3
"""ice_test.py: rs6809's ICE on a simulated rs6809-fpga machine.

Starts the Verilator simulation with its serial port on TCP, rs6809 with
--fpga tcp:..., and drives the ICE's HTTP API: wait for a prompt on the
console, stop, read registers, step, set a breakpoint and run to it,
read the OS's process table, and continue.

usage: ice_test.py 6809|68000 SIM IMAGE RS6809 [extra rs6809 args]
"""
import json
import subprocess
import sys
import time
import urllib.request

cpu, sim, image, rs = sys.argv[1:5]
extra = sys.argv[5:]
SIM_PORT, ICE_PORT = 6820, 6819
base = f"http://127.0.0.1:{ICE_PORT}"


def api(path, body=None):
    req = urllib.request.Request(base + path, data=body, method="POST" if body is not None else "GET")
    with urllib.request.urlopen(req, timeout=600) as r:
        t = r.read().decode()
    try:
        return json.loads(t)
    except ValueError:
        return t


def console():
    return api("/api/console?since=0")["text"]


def wait_for(text, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        c = console()
        if text in c:
            return c
        time.sleep(2)
    print(console()[-2000:])
    raise SystemExit(f"FAIL: no {text!r} within {timeout} s")


def state():
    return api("/api/state")


simp = subprocess.Popen([sim, "-s", image, "-t", str(SIM_PORT)], stderr=subprocess.DEVNULL)
time.sleep(1)
rsp = subprocess.Popen([rs, "--cpu", cpu, "--fpga", f"tcp:127.0.0.1:{SIM_PORT}", "--ice", f"127.0.0.1:{ICE_PORT}"] + extra,
                       stdout=subprocess.DEVNULL)
try:
    for _ in range(120):
        try:
            api("/api/state")
            break
        except OSError:
            time.sleep(1)
    prompt = {"6809": "OS9:", "68000": "login:"}.get(cpu, "OS9:")
    wait_for(prompt, 3000)
    print("console reached", repr(prompt))
    api("/api/pause")
    s = state()
    regs = s["regs"]
    print("stopped:", s.get("stop"), "PC=%X" % regs["pc"])
    pcs = []
    for _ in range(3):
        api("/api/step")
        pcs.append(state()["regs"]["pc"])
    print("steps:", " ".join("%X" % p for p in pcs))
    assert len(set(pcs)) > 1 or pcs[0] != regs["pc"], "PC did not move"
    # a breakpoint on the instruction we are at: running loops back to it
    bp = pcs[-1]
    api(f"/api/bp?addr={bp:x}")
    api("/api/run")
    t0 = time.time()
    while time.time() - t0 < 600:
        s = state()
        if not s.get("running"):
            break
        time.sleep(1)
    print("after run:", s.get("stop"), "PC=%X" % s["regs"]["pc"])
    hit = s["regs"]["pc"] == bp
    api(f"/api/bp?addr={bp:x}&op=del")
    procs = api("/api/os/procs")
    print("processes:", json.dumps(procs)[:300])
    api("/api/run")
    print("RESULT:", "PASS" if hit else "FAIL (breakpoint not hit)")
    sys.exit(0 if hit else 1)
finally:
    rsp.terminate()
    simp.terminate()
