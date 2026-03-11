# ============================================================================
# CELL 1 — Install & upload
# ============================================================================
!pip install tensorflow -q

from google.colab import files
import numpy as np
import tensorflow as tf

print("Upload your .tflite model:")
uploaded = files.upload()
model_path = list(uploaded.keys())[0]

# ============================================================================
# CELL 2 — Extract CONV1+Pool1 output in channel-first order
# ============================================================================

# ---- Load image_hex.mem (same file used by hardware) ----
print("Upload image_hex.mem:")
uploaded_img = files.upload()
mem_path = list(uploaded_img.keys())[0]

# Read int8 hex values from .mem file
with open(mem_path, 'r') as f:
    lines = [l.strip() for l in f if l.strip()]

# Convert hex → int8 (two's complement)
img_int8 = np.array([np.int8(int(h, 16) if int(h,16) < 128 else int(h,16) - 256)
                     for h in lines], dtype=np.int8).reshape(28, 28)

print(f"[IMAGE] Loaded {len(lines)} pixels from {mem_path}")
print(f"[IMAGE] int8 range: [{img_int8.min()}, {img_int8.max()}]")

# Convert back to uint8 for TFLite input (model expects uint8, zp=1)
# Hardware stores: int8 = uint8 - 128  →  uint8 = int8 + 128
img_uint8 = (img_int8.astype(np.int32) + 128).astype(np.uint8)
print(f"[IMAGE] uint8 range: [{img_uint8.min()}, {img_uint8.max()}]")

# ---- Build intermediate model that outputs after Pool1 ----
# We need tensor index 14: sequential_2_1/average_pooling2d_4_1/AvgPool
# shape = [1, 12, 12, 6]  (TFLite channel-last)

interpreter = tf.lite.Interpreter(model_path=model_path)
interpreter.allocate_tensors()

input_details  = interpreter.get_input_details()[0]
tensor_details = interpreter.get_tensor_details()

# Find the Pool1 output tensor
pool1_tensor = None
for t in tensor_details:
    if 'average_pooling2d_4' in t['name'] or 'AvgPool' in t['name']:
        if len(t['shape']) == 4 and t['shape'][1] == 12:  # Pool1 output is 12x12
            pool1_tensor = t
            break

if pool1_tensor is None:
    # Fallback: find by shape [1,12,12,6]
    for t in tensor_details:
        if list(t['shape']) == [1, 12, 12, 6]:
            pool1_tensor = t
            break

print(f"\n[POOL1] Found tensor: index={pool1_tensor['index']}")
print(f"        name  = {pool1_tensor['name']}")
print(f"        shape = {pool1_tensor['shape']}")
print(f"        scale = {pool1_tensor['quantization'][0]:.6f}")
print(f"        zp    = {pool1_tensor['quantization'][1]}")

# ---- Run inference with output tensor added ----
interpreter.reset_all_variables()

# Add the intermediate tensor as output
interpreter.set_tensor(input_details['index'],
                       img_uint8.reshape(input_details['shape']))

# Use invoke then get_tensor for intermediate results
interpreter.invoke()
pool1_out_tflite = interpreter.get_tensor(pool1_tensor['index'])  # [1,12,12,6]
pool1_out_tflite = pool1_out_tflite[0]                            # [12,12,6]

print(f"\n[POOL1] TFLite output shape (channel-last): {pool1_out_tflite.shape}")
print(f"        dtype  = {pool1_out_tflite.dtype}")
print(f"        range  = [{pool1_out_tflite.min()}, {pool1_out_tflite.max()}]")

# ---- Convert to channel-first to match hardware ----
# TFLite: [H, W, C] = [12, 12, 6]
# Hardware: [C, H, W] = [6, 12, 12]
# addr = ch * H * W + row * W + col
pool1_out_hw = np.transpose(pool1_out_tflite, (2, 0, 1))  # [6, 12, 12]
print(f"\n[POOL1] Hardware order shape (channel-first): {pool1_out_hw.shape}")

# ---- Print flat values (channel-first, matches hardware SRAM) ----
flat = pool1_out_hw.flatten().astype(np.int8)
print(f"\n[POOL1] Flat values (channel-first, {flat.size} total):")
print(f"        First 24 values: {flat[:24].tolist()}")
print(f"        Last  12 values: {flat[-12:].tolist()}")

# ---- Print per-channel feature maps ----
print(f"\n[POOL1] Per-channel output (int8):")
for ch in range(6):
    fm = pool1_out_hw[ch]   # [12, 12]
    print(f"\n  Channel {ch}  (min={fm.min()}, max={fm.max()}):")
    for r in range(12):
        row_vals = [f"{int(v):4d}" for v in fm[r]]
        print(f"    row{r:2d}: {'  '.join(row_vals)}")

# ---- Write to .mem file (channel-first, matches hardware SRAM layout) ----
with open("conv1_pool1_output.mem", 'w') as f:
    for v in flat:
        f.write(f"{int(v) & 0xFF:02x}\n")
print(f"\n[WROTE] conv1_pool1_output.mem  ({flat.size} entries)")
print(f"        Layout: addr = ch*144 + row*12 + col")
print(f"        addr 0..143   = channel 0")
print(f"        addr 144..287 = channel 1")
print(f"        ...")
print(f"        addr 720..863 = channel 5")

# ============================================================================
# CELL 3 — Download
# ============================================================================
from google.colab import files
files.download("conv1_pool1_output.mem")
print("Done!")
