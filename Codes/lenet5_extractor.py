# ============================================================================
# LeNet-5 TFLite Weight Extractor — Colab Version
# Verified against model tensor layout:
#   idx=11  [6,  5, 5, 1]   → CONV1
#   idx= 9  [16, 5, 5, 6]   → CONV2
#   idx= 7  [120, 256]      → FC1
#   idx= 5  [84,  120]      → FC2
#   idx= 3  [10,  84]       → FC3
#
# HW memory layout expected:
#   CONV : [out_ch, in_ch, kH, kW]  row-major spatial per channel
#   FC1  : columns permuted from TFLite channel-last → HW channel-first
#   FC2/3: sequential, no reorder
# ============================================================================

# ============================================================================
# CELL 1 — Install / import
# ============================================================================
import subprocess
subprocess.run(["pip", "install", "tflite", "tensorflow", "pillow", "numpy", "-q"])

import numpy as np
import tensorflow as tf
from PIL import Image
import os, struct
print(f"TF version: {tf.__version__}")

# ============================================================================
# CELL 2 — Upload model (and optional image)
# ============================================================================
from google.colab import files

print("Upload your .tflite model file:")
uploaded   = files.upload()
model_path = list(uploaded.keys())[0]
print(f"✓ Model: {model_path}")

print("\nUpload digit image (PNG/JPG) — or Cancel to use MNIST sample:")
try:
    uploaded_img = files.upload()
    image_path   = list(uploaded_img.keys())[0] if uploaded_img else None
except:
    image_path = None

# ============================================================================
# CELL 3 — Load model
# ============================================================================
interpreter    = tf.lite.Interpreter(model_path=model_path)
interpreter.allocate_tensors()
tensor_details = interpreter.get_tensor_details()
input_details  = interpreter.get_input_details()[0]
output_details = interpreter.get_output_details()[0]

with open(model_path, 'rb') as f:
    model_buf = bytearray(f.read())

print(f"\n[MODEL] Input : shape={input_details['shape']}  "
      f"scale={input_details['quantization'][0]:.8f}  "
      f"zp={input_details['quantization'][1]}")
print(f"[MODEL] Output: shape={output_details['shape']}")

# ============================================================================
# CELL 4 — Flatbuffer weight reader
# ============================================================================
def read_flatbuffer_tensor(t_detail, buf):
    """
    Read a constant tensor directly from the TFLite flatbuffer.
    This is the ONLY reliable method in TF 2.x — get_tensor() returns
    garbage for constant (weight) tensors.
    """
    try:
        from tflite.Model import Model
        model = Model.GetRootAsModel(bytes(buf), 0)
    except AttributeError:
        import tflite.Model as TFLModel
        model = TFLModel.Model.GetRootAs(bytes(buf), 0)

    sg         = model.Subgraphs(0)
    tensor_obj = sg.Tensors(t_detail['index'])
    buf_obj    = model.Buffers(tensor_obj.Buffer())

    if buf_obj.DataLength() == 0:
        raise RuntimeError(
            f"Tensor idx={t_detail['index']} '{t_detail['name']}' "
            f"has empty buffer — it is an activation, not a weight."
        )

    raw = bytes([buf_obj.Data(j) for j in range(buf_obj.DataLength())])
    return np.frombuffer(raw, dtype=t_detail['dtype']).reshape(t_detail['shape'])

# ============================================================================
# CELL 5 — Identify weight tensors by name
# ============================================================================
# From diagnostic output:
#   Real weights have names like "tfl.pseudo_qconst*"
#   Activations have names containing relu/avgpool/reshape/matmul/conv/quantize
WEIGHT_KEYWORDS     = {"pseudo_qconst", "kernel", "depthwise_kernel", "weight"}
ACTIVATION_KEYWORDS = {"relu", "avgpool", "reshape", "matmul",
                       "biasadd", "convolution", "quantize", "stateful", "flatten"}

def is_weight(t):
    name = t['name'].lower()
    return (any(k in name for k in WEIGHT_KEYWORDS) and
            not any(k in name for k in ACTIVATION_KEYWORDS))

def is_bias(t):
    name = t['name'].lower()
    return (t['dtype'] == np.int32 and
            len(t['shape']) == 1 and
            t['quantization'][0] != 0.0 and
            any(k in name for k in WEIGHT_KEYWORDS))

weight_tensors = [t for t in tensor_details if is_weight(t)]
bias_tensors   = [t for t in tensor_details if is_bias(t)]

print("\n[WEIGHTS] Found:")
for t in weight_tensors:
    print(f"  idx={t['index']:3d}  shape={str(t['shape']):20s}  "
          f"scale={t['quantization'][0]:.8f}  name={t['name']}")

print("\n[BIASES] Found:")
for t in bias_tensors:
    print(f"  idx={t['index']:3d}  shape={str(t['shape']):15s}  "
          f"scale={t['quantization'][0]:.8f}  name={t['name']}")

# ============================================================================
# CELL 6 — Sort into execution order: CONV1 → CONV2 → FC1 → FC2 → FC3
# ============================================================================
# Your model: indices are 11,9,7,5,3 — descending = execution order reversed.
# Sort descending by index → ascending execution order.
weight_tensors.sort(key=lambda x: x['index'], reverse=True)
bias_tensors.sort(  key=lambda x: x['index'], reverse=True)

layer_names = ["CONV1", "CONV2", "FC1", "FC2", "FC3"]
print("\n[ORDER] Execution order (should be CONV1→CONV2→FC1→FC2→FC3):")
for i, t in enumerate(weight_tensors):
    lname = layer_names[i] if i < len(layer_names) else f"L{i}"
    print(f"  [{lname}]  idx={t['index']}  shape={t['shape']}")

# ============================================================================
# CELL 7 — Extract and flatten weights for hardware
# ============================================================================
#
# CONV layout expected by HW:
#   Shape in TFLite : [out_ch, kH, kW, in_ch]   (OHWI)
#   Shape HW expects: [out_ch, in_ch, kH, kW]   (OIHW)
#
#   Memory for filter f:
#     bytes [0  .. kH*kW-1      ] = channel 0 pixels, row-major
#     bytes [kH*kW .. 2*kH*kW-1 ] = channel 1 pixels, row-major
#     ...
#
# FC1 layout:
#   avg_pool stores output channel-first:
#     hw_addr = ch * H * W  +  r * W  +  c
#   TFLite FC1 weight columns assume channel-last:
#     tflite_col = r * W * C  +  c * C  +  ch
#   → must permute columns: w_hw[:, hw_idx] = w_tflite[:, tflite_idx]
#
# FC2 / FC3:
#   FC outputs written sequentially → no reorder needed.
#
all_weights    = []
weight_offsets = []
w_offset       = 0

# Find CONV2 to get fC for FC1 permutation
conv_tensors = [t for t in weight_tensors if len(t['shape']) == 4]
fC_conv2     = int(conv_tensors[-1]['shape'][0])   # CONV2 out_ch = 16
print(f"\n[FC1] fC_conv2 (pool2 channels) = {fC_conv2}")

for i, t in enumerate(weight_tensors):
    lname = layer_names[i] if i < len(layer_names) else f"L{i}"
    weight_offsets.append(w_offset)

    w = read_flatbuffer_tensor(t, model_buf)

    if len(w.shape) == 4:
        # ------------------------------------------------------------------
        # CONV layer: OHWI → OIHW
        # ------------------------------------------------------------------
        out_ch, kH, kW, in_ch = w.shape
        w_oihw = w.transpose(0, 3, 1, 2)          # [out_ch, in_ch, kH, kW]
        flat   = w_oihw.reshape(out_ch, -1).flatten().astype(np.int8)

        # Verification print — compare filter0, ch0 row0 with Netron
        print(f"\n[{lname}] OHWI {w.shape} → OIHW {w_oihw.shape}")
        print(f"  filter0, ch0, row0 (5 vals): {w_oihw[0, 0, 0, :].tolist()}")
        print(f"  Netron shows [filter0,r0,c0,ch0]: {w[0,0,0,0]}  "
              f"[filter0,r0,c0,ch1 if any]: {w[0,0,0,min(1,in_ch-1)]}")

    else:
        # ------------------------------------------------------------------
        # FC layer
        # ------------------------------------------------------------------
        out_ch, in_ch = w.shape
        is_fc1 = (in_ch % fC_conv2 == 0) and (in_ch > fC_conv2)

        if is_fc1:
            # ----------------------------------------------------------------
            # FC1: permute columns TFLite channel-last → HW channel-first
            # ----------------------------------------------------------------
            fC      = fC_conv2                     # 16
            spatial = in_ch // fC                  # 256 // 16 = 16
            fH      = int(round(spatial ** 0.5))   # 4
            fW      = spatial // fH                # 4
            assert fH * fW * fC == in_ch, \
                f"FC1 shape mismatch: {fH}x{fW}x{fC} = {fH*fW*fC} != {in_ch}"

            print(f"\n[{lname}] FC1 shape={w.shape}  feature map=[{fC},{fH},{fW}]")
            print(f"  Permuting columns: TFLite [H,W,C] → HW [C,H,W]")

            # perm[hw_idx] = tflite_idx
            # hw_idx     = ch*fH*fW + r*fW + c
            # tflite_idx = r*fW*fC  + c*fC + ch
            perm = np.empty(in_ch, dtype=np.int32)
            for ch in range(fC):
                for r in range(fH):
                    for c in range(fW):
                        hw_idx       = ch * fH * fW + r * fW + c
                        tflite_idx   = r  * fW * fC + c * fC + ch
                        perm[hw_idx] = tflite_idx

            w_perm = w[:, perm]
            flat   = w_perm.flatten().astype(np.int8)

            # Sanity: neuron 0 dot product must be same before and after
            test_input_chfirst = np.zeros(in_ch, dtype=np.int8)
            test_input_chfirst[0] = 1                             # ch=0,r=0,c=0 = 1
            test_input_chlast  = np.zeros(in_ch, dtype=np.int8)
            test_input_chlast[0]  = 1                             # r=0,c=0,ch=0 = 1
            dot_orig  = int(w[0].astype(np.int32) @ test_input_chlast.astype(np.int32))
            dot_perm  = int(w_perm[0].astype(np.int32) @ test_input_chfirst.astype(np.int32))
            print(f"  Sanity (should match): orig_dot={dot_orig}  perm_dot={dot_perm}  "
                  f"{'✓ OK' if dot_orig == dot_perm else '✗ MISMATCH'}")

        else:
            # ----------------------------------------------------------------
            # FC2 / FC3: no reorder
            # ----------------------------------------------------------------
            print(f"\n[{lname}] FC shape={w.shape}  sequential, no reorder")
            flat = w.flatten().astype(np.int8)

    all_weights.extend(flat.tolist())
    w_offset += flat.size

print(f"\n[WEIGHTS] Total bytes: {len(all_weights)}")

# ============================================================================
# CELL 8 — Extract biases
# ============================================================================
all_biases   = []
bias_offsets = []
b_offset     = 0

for i, t in enumerate(bias_tensors):
    lname = layer_names[i] if i < len(layer_names) else f"L{i}"
    bias_offsets.append(b_offset)
    b = read_flatbuffer_tensor(t, model_buf).astype(np.int32)
    all_biases.extend(b.tolist())
    b_offset += b.size
    print(f"[{lname}] bias shape={b.shape}  first4={b[:4].tolist()}")

print(f"\n[BIASES] Total: {len(all_biases)}")

# ============================================================================
# CELL 9 — Input image
# ============================================================================
input_shape = input_details['shape']   # [1, H, W, C]
H, W        = int(input_shape[1]), int(input_shape[2])

if image_path and os.path.exists(image_path):
    img    = Image.open(image_path).convert('L').resize((W, H))
    img_np = np.array(img, dtype=np.float32)
    print(f"\n[IMAGE] Loaded {image_path} → {W}x{H}")
else:
    print("\n[IMAGE] Fetching MNIST sample...")
    (x_train, y_train), _ = tf.keras.datasets.mnist.load_data()
    SAMPLE_IDX  = 0
    img_np      = x_train[SAMPLE_IDX].astype(np.float32)
    true_label  = int(y_train[SAMPLE_IDX])
    print(f"[IMAGE] MNIST idx={SAMPLE_IDX}  true label={true_label}")

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plt.figure(figsize=(2, 2))
    plt.imshow(img_np, cmap='gray')
    plt.title(f"MNIST: {true_label}")
    plt.axis('off')
    plt.savefig("mnist_sample.png", bbox_inches='tight', dpi=100)
    plt.close()
    from IPython.display import display, Image as IPImage
    display(IPImage("mnist_sample.png"))

# quantize: int8 = uint8 - 128
img_uint8 = img_np.astype(np.uint8)
img_int8  = (img_uint8.astype(np.int32) - 128).astype(np.int8)

print(f"[IMAGE] uint8 range: [{img_uint8.min()}, {img_uint8.max()}]")
print(f"[IMAGE] int8  range: [{img_int8.min()},  {img_int8.max()}]  (= pixel-128)")

# ============================================================================
# CELL 10 — Reference inference
# ============================================================================
interpreter.set_tensor(input_details['index'], img_uint8.reshape(input_shape))
interpreter.invoke()
output    = interpreter.get_tensor(output_details['index'])[0]
predicted = int(np.argmax(output))
print(f"\n[REFERENCE] Predicted: {predicted}")
print(f"[REFERENCE] Logits   : {output.tolist()}")

# ============================================================================
# CELL 11 — Write .mem files
# ============================================================================
with open("all_weights.mem", 'w') as f:
    for v in all_weights:
        f.write(f"{int(v) & 0xFF:02x}\n")
print(f"\n[WROTE] all_weights.mem  ({len(all_weights)} lines)")

with open("all_biases.mem", 'w') as f:
    for v in all_biases:
        f.write(f"{int(v) & 0xFFFFFFFF:08x}\n")
print(f"[WROTE] all_biases.mem   ({len(all_biases)} lines)")

with open("image_hex.mem", 'w') as f:
    for px in img_int8.flatten():
        f.write(f"{int(px) & 0xFF:02x}\n")
print(f"[WROTE] image_hex.mem    ({img_int8.size} lines)")

# ============================================================================
# CELL 12 — Write model_info.txt
# ============================================================================
with open("model_info.txt", 'w') as f:
    f.write("LeNet-5 Hardware Weight Configuration\n")
    f.write("=" * 60 + "\n\n")
    f.write(f"Input scale = {input_details['quantization'][0]:.10f}\n")
    f.write(f"Input zp    = {input_details['quantization'][1]}\n\n")
    f.write("Layer Details\n" + "-" * 60 + "\n")

    for i, t in enumerate(weight_tensors):
        lname  = layer_names[i] if i < len(layer_names) else f"L{i}"
        w      = read_flatbuffer_tensor(t, model_buf)
        nb     = bias_tensors[i]['shape'][0] if i < len(bias_tensors) else 0

        if len(w.shape) == 4:
            out_ch, kH, kW, in_ch = w.shape
            kernel, fc = kH, 0
        else:
            out_ch, in_ch = w.shape
            kernel, fc    = 1, 1

        f.write(f"\nLayer {i} — {lname}\n")
        f.write(f"  tflite_shape   = {list(w.shape)}\n")
        f.write(f"  out_channels   = {out_ch}\n")
        f.write(f"  in_channels    = {in_ch}\n")
        f.write(f"  kernel         = {kernel}\n")
        f.write(f"  fc_mode        = {fc}\n")
        f.write(f"  weight_offset  = {weight_offsets[i]}\n")
        f.write(f"  weight_total   = {w.size}\n")
        f.write(f"  bias_offset    = {bias_offsets[i]}\n")
        f.write(f"  bias_total     = {nb}\n")
        f.write(f"  weight_scale   = {t['quantization'][0]:.10f}\n")
        f.write(f"  weight_zp      = {t['quantization'][1]}\n")
        if i < len(bias_tensors):
            f.write(f"  bias_scale     = {bias_tensors[i]['quantization'][0]:.10f}\n")
            f.write(f"  bias_zp        = {bias_tensors[i]['quantization'][1]}\n")

    f.write("\n\n" + "=" * 60 + "\n")
    f.write("SystemVerilog cfg_ arrays\n")
    f.write("=" * 60 + "\n\n")
    f.write("// cfg_in_ch must be 9 bits to hold 256\n")
    f.write("logic [2:0]  cfg_kernel  [NUM_LAYERS];\n")
    f.write("logic [8:0]  cfg_in_ch   [NUM_LAYERS];  // 9 bits!\n")
    f.write("logic [7:0]  cfg_out_ch  [NUM_LAYERS];\n")
    f.write("logic        cfg_fc_mode [NUM_LAYERS];\n")
    f.write("logic [15:0] cfg_w_off   [NUM_LAYERS];\n")
    f.write("logic [14:0] cfg_w_total [NUM_LAYERS];\n")
    f.write("logic [7:0]  cfg_b_off   [NUM_LAYERS];\n")
    f.write("logic [7:0]  cfg_b_total [NUM_LAYERS];\n\n")

    for i, t in enumerate(weight_tensors):
        lname  = layer_names[i] if i < len(layer_names) else f"L{i}"
        w      = read_flatbuffer_tensor(t, model_buf)
        nb     = bias_tensors[i]['shape'][0] if i < len(bias_tensors) else 0

        if len(w.shape) == 4:
            out_ch, kH, kW, in_ch = w.shape
            kernel, fc = kH, 0
        else:
            out_ch, in_ch = w.shape
            kernel, fc    = 1, 1

        f.write(f"// {lname}\n")
        f.write(f"cfg_kernel [{i}] = 3'd{kernel};  "
                f"cfg_in_ch  [{i}] = 9'd{in_ch};  "
                f"cfg_out_ch [{i}] = 8'd{out_ch};  "
                f"cfg_fc_mode[{i}] = 1'b{fc};\n")
        f.write(f"cfg_w_off  [{i}] = 16'd{weight_offsets[i]};  "
                f"cfg_w_total[{i}] = 15'd{w.size};  "
                f"cfg_b_off  [{i}] = 8'd{bias_offsets[i]};  "
                f"cfg_b_total[{i}] = 8'd{nb};\n\n")

    f.write(f"\nReference inference:\n")
    f.write(f"  Predicted = {predicted}\n")
    for j, v in enumerate(output):
        f.write(f"  digit {j}: {int(v):5d}\n")

print(f"[WROTE] model_info.txt")

# ============================================================================
# CELL 13 — Verify: first filter of CONV1 matches Netron
# ============================================================================
print("\n" + "=" * 60)
print("VERIFICATION — compare these with Netron")
print("=" * 60)
conv1_t = weight_tensors[0]
conv1_w = read_flatbuffer_tensor(conv1_t, model_buf)  # [6, 5, 5, 1] OHWI
print(f"\nCONV1 raw TFLite shape: {conv1_w.shape}  (OHWI)")
print(f"CONV1 filter0, all spatial, ch0 — Netron order [kH,kW]:")
print(conv1_w[0, :, :, 0])   # should match Netron's filter 0 values exactly

conv1_hw = conv1_w.transpose(0, 3, 1, 2)  # OIHW
print(f"\nCONV1 after transpose to OIHW {conv1_hw.shape}:")
print(f"  filter0, ch0, row-major flat (25 vals):")
print(conv1_hw[0, 0].flatten().tolist())

# ============================================================================
# CELL 14 — Download
# ============================================================================
from google.colab import files
for fname in ["all_weights.mem", "all_biases.mem", "image_hex.mem", "model_info.txt"]:
    files.download(fname)
    print(f"↓ {fname}")
print("\nDone!")
