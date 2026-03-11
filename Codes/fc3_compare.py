def to_signed(v):
    return v - 256 if v > 127 else v

hw_raw = [int(l.strip(),16) for l in open("fc3_output_hex.txt")      if l.strip()]
sw_raw = [int(l.strip(),16) for l in open("fc3_golden_reference.mem") if l.strip()]

hw = [to_signed(v) for v in hw_raw]
sw = [to_signed(v) for v in sw_raw]

print(f"{'Class':>6}  {'HW':>6}  {'SW':>6}  {'match':>6}")
print("-"*30)
for i in range(10):
    marker = " ← MAX" if i == hw.index(max(hw)) else ""
    match  = "✓" if hw[i] == sw[i] else f"Δ{hw[i]-sw[i]:+d}"
    print(f"  [{i}]   {hw[i]:5d}   {sw[i]:5d}   {match}{marker}")

print(f"\nPredicted HW: {hw.index(max(hw))}")
print(f"Predicted SW: {sw.index(max(sw))}")
print(f"Match: {'✓ PASS' if hw.index(max(hw))==sw.index(max(sw)) else '✗ FAIL'}")
