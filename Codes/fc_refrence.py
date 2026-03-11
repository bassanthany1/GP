import numpy as np
import tensorflow as tf

# ---- Load image ----
with open("image_hex.mem", 'r') as f:
    lines = [l.strip() for l in f if l.strip()]

img_int8 = np.array([int(h,16) if int(h,16) < 128 else int(h,16)-256
                     for h in lines], dtype=np.int8).reshape(28,28)
img_uint8 = (img_int8.astype(np.int32) + 128).astype(np.uint8)

# ---- Run TFLite with all tensors preserved ----
interpreter = tf.lite.Interpreter(
    model_path="lenet5_npu_int8_per_tensor.tflite",
    experimental_preserve_all_tensors=True
)
interpreter.allocate_tensors()
interpreter.set_tensor(interpreter.get_input_details()[0]['index'],
                       img_uint8.reshape(1,28,28,1))
interpreter.invoke()

# ---- FC3 output: read as int8 then convert to hw uint8 (add 128) ----
# tensor 20 is int8 internally, ZP_next=26 in hardware
# hardware output = int8_val + 128  (to match uint8 with ZP=26 offset)
raw = interpreter.get_tensor(20).flatten()  # int8 values
print(f"Raw int8 : {raw.tolist()}")
print(f"Predicted: {np.argmax(raw)} (should be 5)")

# Write as uint8 (add 128 to match hardware ZP convention)
with open("fc3_golden_reference.mem", 'w') as f:
    for v in raw:
        f.write(f"{(int(v) & 0xff):02x}\n")
