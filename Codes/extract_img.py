import numpy as np
import tensorflow as tf
from PIL import Image
import os

# ============================
# Load or choose image
# ============================
image_path = None   

H = 28
W = 28

if image_path and os.path.exists(image_path):
    img = Image.open(image_path).convert('L').resize((W, H))
    img_np = np.array(img, dtype=np.float32)
    print(f"[IMAGE] Loaded {image_path}")
else:
    print("[IMAGE] Using MNIST sample")
    (x_train, y_train), _ = tf.keras.datasets.mnist.load_data()
    SAMPLE_IDX = 0 #change to get different image
    img_np = x_train[SAMPLE_IDX].astype(np.float32)
    print(f"[IMAGE] MNIST label = {y_train[SAMPLE_IDX]}")

# ============================
# Quantization
# ============================
# TFLite input = uint8
img_uint8 = img_np.astype(np.uint8)

# Hardware expects int8
img_int8 = (img_uint8.astype(np.int32) - 128).astype(np.int8)

print(f"[IMAGE] uint8 range: {img_uint8.min()} .. {img_uint8.max()}")
print(f"[IMAGE] int8 range : {img_int8.min()} .. {img_int8.max()}")

# ============================
# Write MEM file
# ============================
with open("image_hex.mem", 'w') as f:
    for px in img_int8.flatten():
        f.write(f"{int(px) & 0xFF:02x}\n")

print(f"[WROTE] image_hex2.mem ({img_int8.size} values)")
