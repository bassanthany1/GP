import numpy as np

def read_mem_signed(filename):
    vals = []
    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            v = int(line, 16)
            if v > 127: v -= 256
            vals.append(v)
    return vals

hw = np.array(read_mem_signed("fc1_output_hex.txt"), dtype=np.int32)
sw = np.array(read_mem_signed("fc1_golden_reference.mem"), dtype=np.int32)

print(f"HW: {len(hw)}  SW: {len(sw)}")

TOLERANCE = 3
diff = np.abs(hw - sw)

print(f"\n{'='*50}")
print(f"Exact:     {np.sum(diff==0)}/120 ({100*np.sum(diff==0)/120:.1f}%)")
print(f"Within ±{TOLERANCE}: {np.sum(diff<=TOLERANCE)}/120({100*np.sum(diff<=TOLERANCE)/120:.1f}%)")
print(f"Max error: {diff.max()}")

print(f"\n{'idx':>4} {'HW':>6} {'SW':>6} {'diff':>6}")
print("-"*25)
for i in range(min(30, len(hw), len(sw))):
    mark = " ✓" if diff[i]==0 else ""
    print(f"{i:>4} {hw[i]:>6} {sw[i]:>6} {diff[i]:>6}{mark}")

fail_idx = np.where(diff > TOLERANCE)[0]
if len(fail_idx):
    print(f"\nFailures (diff > {TOLERANCE}):")
    print(f"  {'idx':>4}  {'HW':>6}  {'SW':>6}  {'diff':>5}")
    for idx in fail_idx[:20]:
        print(f"  {idx:4d}  {hw[idx]:6d}  {sw[idx]:6d}  {hw[idx]-sw[idx]:+5d}")
else:
    print(f"\n✓ ALL PASS within ±{TOLERANCE}!")
