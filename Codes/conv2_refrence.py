import numpy as np
import tensorflow as tf

# ---- Load image from image_hex.mem ----
img_int8 = []
with open("image_hex.mem", 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        val = int(line, 16)
        if val > 127:
            val -= 256
        img_int8.append(val)

img_int8 = np.array(img_int8, dtype=np.int8).reshape(28, 28)
print(f"Image loaded: {img_int8.shape}  min={img_int8.min()}  max={img_int8.max()}")

# Convert back to uint8 for TFLite (hardware stores int8 = uint8 - 128)
img_uint8 = (img_int8.astype(np.int32) + 128).astype(np.uint8).reshape(1, 28, 28, 1)
print(f"uint8 image: min={img_uint8.min()}  max={img_uint8.max()}")

# ---- Run inference ----
interpreter = tf.lite.Interpreter(model_path="lenet5_npu_int8_per_tensor.tflite")
interpreter.allocate_tensors()
input_details = interpreter.get_input_details()[0]

interpreter.set_tensor(input_details['index'], img_uint8)
interpreter.invoke()

# ---- Find CONV2+Pool2 output tensor: shape [1,4,4,16] int8 ----
for t in interpreter.get_tensor_details():
    if list(t['shape']) == [1, 4, 4, 16] and t['dtype'] == np.int8:
        data = interpreter.get_tensor(t['index'])
        print(f"Found at index {t['index']}: shape={data.shape}  zp={t['quantization'][1]}")
        conv2_pool2_sw = data[0]  # [4,4,16] channel-last
        break

# Convert to channel-first [16,4,4] to match hardware
flat = conv2_pool2_sw.transpose(2, 0, 1).flatten()
print(f"Total values: {flat.size}")   # should be 256
print(f"First 16 values: {flat[:16].tolist()}")

# Write reference .mem file
with open("conv2_pool2_output.mem", 'w') as f:
    for v in flat:
        f.write(f"{int(v) & 0xFF:02x}\n")

print("[WROTE] conv2_pool2_output.mem  (256 values, channel-first [16,4,4])")
