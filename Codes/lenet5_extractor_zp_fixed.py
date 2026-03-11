# ============================================================================
# LeNet-5 TFLite Weight Extractor — Standalone Version (no TensorFlow)
# ZP-CORRECTED BIASES
# ============================================================================
#
# KEY FIX: Each layer's bias is corrected for input zero-point:
#
#   The hardware computes:  acc = Σ input_q * weight_q + bias_q
#   The correct formula is: acc = Σ (input_q - input_zp) * weight_q + bias_q
#
#   Expanding: acc_correct = Σ input_q * weight_q
#                           - input_zp * Σ weight_q
#                           + bias_q
#
#   So:  bias_corrected[f] = bias[f] - input_zp * sum(weights[f])
#
#   Since input_zp = -128 for all layers:
#        bias_corrected[f] = bias[f] + 128 * sum(weights[f])
#
# This correction is applied per output channel, per layer.
# No RTL changes needed — only the .mem file changes.
#
# ============================================================================
#
# Layer quantization (from Netron):
#   CONV1: in_scale=0.00393695  w_scale=0.00726069  out_scale=0.01473035
#   CONV2: in_scale=0.01473035  w_scale=0.01237743  out_scale=0.04254789
#   FC1:   in_scale=0.04254789  w_scale=0.00955604  out_scale=0.06301888
#   FC2:   in_scale=0.06301888  w_scale=0.01163609  out_scale=0.08895884
#   FC3:   in_scale=0.08895884  w_scale=0.01727107  out_scale=0.27430886
#
# All input zero-points = -128  (int8 quantization)
#
# ============================================================================

import struct, numpy as np, os, sys

# ── configuration ─────────────────────────────────────────────────────────
MODEL_PATH = "lenet5_npu_int8_per_tensor.tflite"
IMAGE_PATH = "image_hex.mem"          # optional — leave blank to skip

OUT_WEIGHTS = "all_weights.mem"
OUT_BIASES  = "all_biases_zp_fixed.mem"   # NEW file — keeps old one intact
OUT_INFO    = "model_info_zp_fixed.txt"

# ── flatbuffer helpers ─────────────────────────────────────────────────────
def load_model(path):
    with open(path, 'rb') as f:
        return bytearray(f.read())

def ru32(raw, off): return struct.unpack_from('<I', raw, off)[0]
def ri32(raw, off): return struct.unpack_from('<i', raw, off)[0]
def ru16(raw, off): return struct.unpack_from('<H', raw, off)[0]
def rf32(raw, off): return struct.unpack_from('<f', raw, off)[0]

def fb_field(raw, table_off, field_idx):
    vtoff   = table_off - ri32(raw, table_off)
    vt_size = ru16(raw, vtoff)
    slot    = 4 + field_idx * 2
    if slot + 2 > vt_size: return None
    frel = ru16(raw, vtoff + slot)
    return (table_off + frel) if frel else None

def fb_vector(raw, table_off, field_idx):
    foff = fb_field(raw, table_off, field_idx)
    if foff is None: return None, 0
    vec_abs = foff + ru32(raw, foff)
    if vec_abs + 4 > len(raw): return None, 0
    return vec_abs + 4, ru32(raw, vec_abs)

def get_buffer_bytes(raw, buffers_data, buf_idx):
    ptr   = buffers_data + buf_idx * 4
    b_off = ptr + ru32(raw, ptr)
    if b_off >= len(raw): return None
    vt    = b_off - ri32(raw, b_off)
    if vt < 0 or vt >= len(raw): return None
    vts   = ru16(raw, vt)
    if vts < 6: return None
    frel  = ru16(raw, vt + 4)
    if frel == 0: return None
    foff    = b_off + frel
    vec_abs = foff + ru32(raw, foff)
    if vec_abs + 4 > len(raw): return None
    n = ru32(raw, vec_abs)
    if n == 0: return None
    return bytes(raw[vec_abs + 4 : vec_abs + 4 + n])

# ── load and navigate model ────────────────────────────────────────────────
raw = load_model(MODEL_PATH)
model_off = ru32(raw, 0)

buffers_data,   n_buffers  = fb_vector(raw, model_off, 4)
subgraphs_data, _          = fb_vector(raw, model_off, 2)
sg_off = subgraphs_data + ru32(raw, subgraphs_data)
tensors_data,   n_tensors  = fb_vector(raw, sg_off, 0)

print(f"Model loaded: {len(raw)} bytes")
print(f"Buffers: {n_buffers},  Tensors: {n_tensors}")

# ── identify weight/bias buffers by size ──────────────────────────────────
#
# Buffer sizes → content mapping (confirmed by size arithmetic):
#   150  bytes → CONV1 weight [6,5,5,1]   int8
#    24  bytes → CONV1 bias   [6]          int32
#   2400 bytes → CONV2 weight [16,5,5,6]  int8
#    64  bytes → CONV2 bias   [16]         int32
#  30720 bytes → FC1   weight [120,256]   int8
#   480  bytes → FC1   bias   [120]        int32
#  10080 bytes → FC2   weight [84,120]    int8
#   336  bytes → FC2   bias   [84]         int32
#   840  bytes → FC3   weight [10,84]     int8
#    40  bytes → FC3   bias   [10]         int32
#
SIZE_TO_LAYER = {
    150:   ('CONV1', 'weight', (6,5,5,1),   np.int8 ),
    24:    ('CONV1', 'bias',   (6,),         np.int32),
    2400:  ('CONV2', 'weight', (16,5,5,6),  np.int8 ),
    64:    ('CONV2', 'bias',   (16,),        np.int32),
    30720: ('FC1',   'weight', (120,256),   np.int8 ),
    480:   ('FC1',   'bias',   (120,),       np.int32),
    10080: ('FC2',   'weight', (84,120),    np.int8 ),
    336:   ('FC2',   'bias',   (84,),        np.int32),
    840:   ('FC3',   'weight', (10,84),     np.int8 ),
    40:    ('FC3',   'bias',   (10,),        np.int32),
}

weights_raw = {}   # layer_name → np array
biases_raw  = {}

for i in range(n_buffers):
    data = get_buffer_bytes(raw, buffers_data, i)
    if data is None: continue
    n = len(data)
    if n in SIZE_TO_LAYER:
        layer, kind, shape, dtype = SIZE_TO_LAYER[n]
        arr = np.frombuffer(data, dtype=dtype).reshape(shape).copy()
        if kind == 'weight':
            weights_raw[layer] = arr
        else:
            biases_raw[layer]  = arr

layer_order = ['CONV1', 'CONV2', 'FC1', 'FC2', 'FC3']
for lname in layer_order:
    w = weights_raw.get(lname)
    b = biases_raw.get(lname)
    print(f"  {lname}: weight={w.shape if w is not None else 'MISSING'}  "
          f"bias={b.shape if b is not None else 'MISSING'}")

# ── ZP correction ──────────────────────────────────────────────────────────
# All input_zp = -128 for every layer in this model
INPUT_ZP = -128

print("\n[ZP CORRECTION]  bias_corrected[f] = bias[f] - input_zp * sum(weights[f])")
print(f"  input_zp = {INPUT_ZP}  →  bias_corrected[f] = bias[f] + 128 * sum(weights[f])")
print()

biases_corrected = {}

for lname in layer_order:
    w = weights_raw[lname]
    b = biases_raw[lname].copy().astype(np.int64)   # use int64 to avoid overflow

    if len(w.shape) == 4:
        # CONV: w shape [out_ch, kH, kW, in_ch] (TFLite OHWI)
        # sum over all spatial and input-channel dimensions for each output channel
        out_ch = w.shape[0]
        w_sum  = w.reshape(out_ch, -1).sum(axis=1).astype(np.int64)  # [out_ch]
    else:
        # FC: w shape [out_ch, in_ch]
        out_ch = w.shape[0]
        w_sum  = w.sum(axis=1).astype(np.int64)   # [out_ch]

    correction     = (-INPUT_ZP) * w_sum         # = +128 * sum(w)
    b_corrected    = b + correction

    print(f"  {lname}:")
    for f in range(min(out_ch, 6)):
        print(f"    ch{f:3d}: bias={int(b[f]):10d}  "
              f"sum_w={int(w_sum[f]):7d}  "
              f"correction={int(correction[f]):10d}  "
              f"corrected={int(b_corrected[f]):10d}")
    if out_ch > 6:
        print(f"    ... ({out_ch} channels total)")

    biases_corrected[lname] = b_corrected.astype(np.int32)

# ── extract and flatten weights (same as before) ──────────────────────────
print("\n[WEIGHTS] Flattening for hardware (OIHW order)...")

all_weights    = []
weight_offsets = {}

# FC1 column permutation: avg_pool output is channel-first
# hw_addr   = ch * H_pool2 * W_pool2 + r * W_pool2 + c
# tflite_fc1 expects channel-last: col = r*W*C + c*C + ch
# Pool2 output: [16,4,4] → flattened to 256 elements
C2, H2, W2 = 16, 4, 4   # CONV2 out channels, pool2 spatial
assert C2 * H2 * W2 == 256

hw_to_tflite = np.zeros(256, dtype=np.int32)
for ch in range(C2):
    for r in range(H2):
        for c in range(W2):
            hw_idx     = ch * H2 * W2 + r * W2 + c
            tflite_idx = r  * W2 * C2 + c * C2  + ch
            hw_to_tflite[hw_idx] = tflite_idx

w_offset = 0
for lname in layer_order:
    weight_offsets[lname] = w_offset
    w = weights_raw[lname]

    if len(w.shape) == 4:
        # CONV: OHWI → OIHW
        out_ch, kH, kW, in_ch = w.shape
        w_oihw = w.transpose(0, 3, 1, 2)        # [out_ch, in_ch, kH, kW]
        flat   = w_oihw.reshape(out_ch, -1).flatten().astype(np.int8)
        print(f"  {lname}: OHWI{list(w.shape)} → OIHW{list(w_oihw.shape)} → {flat.size} bytes")
    elif lname == 'FC1':
        # FC1: permute columns hw→tflite
        out_ch, in_ch = w.shape
        w_perm = w[:, hw_to_tflite]              # [out_ch, 256] reordered
        flat   = w_perm.flatten().astype(np.int8)
        print(f"  {lname}: {w.shape} + channel permutation → {flat.size} bytes")
    else:
        # FC2, FC3: no reorder
        flat = w.flatten().astype(np.int8)
        print(f"  {lname}: {w.shape} → {flat.size} bytes")

    all_weights.extend(flat.tolist())
    w_offset += flat.size

print(f"  Total weight bytes: {len(all_weights)}")

# ── flatten corrected biases ───────────────────────────────────────────────
print("\n[BIASES] ZP-corrected values:")

all_biases    = []
bias_offsets  = {}
b_offset      = 0

for lname in layer_order:
    bias_offsets[lname] = b_offset
    b = biases_corrected[lname]
    all_biases.extend(b.tolist())
    b_offset += b.size
    print(f"  {lname}: {b.size} values  first4={b[:4].tolist()}")

print(f"  Total bias entries: {len(all_biases)}")

# ── write all_weights.mem (unchanged from before) ─────────────────────────
with open(OUT_WEIGHTS, 'w') as f:
    for v in all_weights:
        f.write(f"{int(v) & 0xFF:02x}\n")
print(f"\n[WROTE] {OUT_WEIGHTS}  ({len(all_weights)} entries)")

# ── write all_biases_zp_fixed.mem ─────────────────────────────────────────
with open(OUT_BIASES, 'w') as f:
    for v in all_biases:
        f.write(f"{int(v) & 0xFFFFFFFF:08x}\n")
print(f"[WROTE] {OUT_BIASES}  ({len(all_biases)} entries)")

# ── write model_info_zp_fixed.txt ─────────────────────────────────────────
# Requantization parameters (TFLite method: M = m0 × 2^(-n), m0 in [0.5,1))
LAYER_SCALES = {
    #        in_scale      w_scale       out_scale    out_zp
    'CONV1': (0.00393695,  0.00726069,   0.01473035,  -128),
    'CONV2': (0.01473035,  0.01237743,   0.04254789,  -128),
    'FC1':   (0.04254789,  0.00955604,   0.06301888,  -128),
    'FC2':   (0.06301888,  0.01163609,   0.08895884,  -128),
    'FC3':   (0.08895884,  0.01727107,   0.27430886,    26),
}

def compute_requant(in_s, w_s, out_s):
    M  = (in_s * w_s) / out_s
    m0 = M; n = 0
    while m0 < 0.5:
        m0 *= 2; n += 1
    m0_fixed    = round(m0 * (2**31))
    total_shift = n + 31
    return M, m0_fixed, total_shift, n

with open(OUT_INFO, 'w') as f:
    f.write("LeNet-5 Hardware Configuration — ZP-CORRECTED BIASES\n")
    f.write("=" * 70 + "\n\n")
    f.write("KEY CHANGE: all_biases_zp_fixed.mem contains\n")
    f.write("  bias_corrected[f] = bias_original[f] + 128 * sum(weights[f])\n")
    f.write("  This compensates for hardware NOT subtracting input_zp=-128\n\n")
    f.write("  No RTL changes required — only load the new .mem file.\n\n")
    f.write("=" * 70 + "\n\n")

    f.write("Requantization Parameters (6-bit shift port required!)\n")
    f.write("-" * 70 + "\n")
    f.write(f"{'Layer':<8} {'M':>14} {'m0_fixed':>14} {'n':>4} {'total_shift':>12} {'out_zp':>7}\n")

    sv_lines = []
    for i, lname in enumerate(layer_order):
        in_s, w_s, out_s, out_zp = LAYER_SCALES[lname]
        M, m0_fixed, total_shift, n = compute_requant(in_s, w_s, out_s)
        f.write(f"{lname:<8} {M:>14.10f} {m0_fixed:>14d} {n:>4d} {total_shift:>12d} {out_zp:>7d}\n")
        sv_lines.append((i, lname, m0_fixed, total_shift, out_zp))

    f.write("\n\nSystemVerilog cfg_ arrays\n")
    f.write("=" * 70 + "\n\n")
    f.write("// IMPORTANT: requant_shift must be [5:0] (6 bits) — max shift=40\n")
    f.write("// Change all [4:0] requant_shift ports to [5:0] throughout hierarchy\n\n")

    for i, lname, m0f, ts, ozp in sv_lines:
        f.write(f"// {lname}\n")
        f.write(f"cfg_rq_scale[{i}] = 32'd{m0f};\n")
        f.write(f"cfg_rq_shift[{i}] = 6'd{ts};\n")
        if ozp < 0:
            f.write(f"cfg_zp_next [{i}] = 8'({ozp});\n\n")
        else:
            f.write(f"cfg_zp_next [{i}] = 8'd{ozp};\n\n")

    f.write("Weight/Bias offsets\n")
    f.write("-" * 70 + "\n")
    f.write(f"{'Layer':<8} {'w_off':>8} {'w_total':>8} {'b_off':>8} {'b_total':>8}\n")
    for lname in layer_order:
        w = weights_raw[lname]
        b = biases_corrected[lname]
        f.write(f"{lname:<8} {weight_offsets[lname]:>8d} {w.size:>8d} "
                f"{bias_offsets[lname]:>8d} {b.size:>8d}\n")

    f.write("\n\nSelf-check: bias correction summary\n")
    f.write("-" * 70 + "\n")
    for lname in layer_order:
        w    = weights_raw[lname]
        b_o  = biases_raw[lname].astype(np.int64)
        b_c  = biases_corrected[lname].astype(np.int64)
        if len(w.shape) == 4:
            w_sum = w.reshape(w.shape[0], -1).sum(axis=1)
        else:
            w_sum = w.sum(axis=1)
        f.write(f"\n{lname}:\n")
        for ch in range(len(b_o)):
            f.write(f"  ch{ch:3d}: orig={int(b_o[ch]):10d}  "
                    f"sum_w={int(w_sum[ch]):7d}  "
                    f"correction={128*int(w_sum[ch]):10d}  "
                    f"fixed={int(b_c[ch]):10d}\n")

print(f"[WROTE] {OUT_INFO}")

# ── quick sanity check ─────────────────────────────────────────────────────
print("\n[SANITY CHECK] CONV1 background: HW(corrected bias) == SW(original bias + ZP sub)")

w1   = weights_raw['CONV1']          # [6,5,5,1] OHWI
b1c  = biases_corrected['CONV1']     # ZP-corrected
b1o  = biases_raw['CONV1']           # original

in_s = 0.00393695; in_zp = -128
out_s= 0.01473035; out_zp= -128
_, m0f, ts, _ = compute_requant(in_s, 0.00726069, out_s)

def requant(v, m0f, ts, ozp):
    p = int(v) * int(m0f)
    if ts > 0:
        half = 1 << (ts - 1)
        p += (half - 1) if p < 0 else half
        p >>= ts
    return max(-128, min(127, p + ozp))

# For a background pixel (all inputs = -128):
# HW:  acc = Σ(-128)*w + b_corrected = Σ(-128)*w + b_orig + 128*Σw = b_orig
# SW:  acc = Σ(-128 - (-128))*w + b_orig = b_orig
# → Both give acc = b_orig → identical output ✓
all_pass = True
for o in range(6):
    ww   = w1[o,:,:,0].astype(np.int64)
    patch= np.full((5,5), -128, dtype=np.int64)

    acc_hw = int(np.sum(patch * ww))          + int(b1c[o])  # HW: no ZP sub
    acc_sw = int(np.sum((patch - in_zp) * ww))+ int(b1o[o])  # SW: ZP sub

    v_hw = max(requant(acc_hw, m0f, ts, out_zp), out_zp)
    v_sw = max(requant(acc_sw, m0f, ts, out_zp), out_zp)

    ok = (v_hw == v_sw)
    if not ok: all_pass = False
    print(f"  Ch{o}: acc_hw={acc_hw} acc_sw={acc_sw}  out_hw={v_hw} out_sw={v_sw}  {'✓' if ok else '✗'}")

if all_pass:
    print("  ✓ PASS: HW with corrected bias == SW reference for all background pixels")

print("\nDone! Files written:")
print(f"  {OUT_WEIGHTS}   — weights (same as before)")
print(f"  {OUT_BIASES}  — ZP-corrected biases (NEW)")
print(f"  {OUT_INFO}  — updated cfg parameters")
print("\nIn your testbench/hardware: replace all_biases.mem → all_biases_zp_fixed.mem")
