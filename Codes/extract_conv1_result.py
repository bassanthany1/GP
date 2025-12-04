#!/usr/bin/env python3
"""
Extract int32 accumulator from Conv1 layer (BEFORE ReLU) in TFLite model
Simplified version for hardware verification
"""

import os
import numpy as np
import tensorflow as tf
from tensorflow.lite.python.interpreter import Interpreter

def load_and_preprocess_image(image_path, target_size=(28, 28)):
    """Load and preprocess image for LeNet-5"""
    from PIL import Image

    img = Image.open(image_path).convert('L')
    img = img.resize(target_size)
    img_array = np.array(img, dtype=np.float32) / 255.0
    img_array = np.expand_dims(img_array, axis=(0, -1))
    return img_array

def to_hex(val, bits=32):
    """Convert signed integer to unsigned hex string"""
    if isinstance(val, np.ndarray):
        val = val.item()

    if bits == 8:
        # For int8, mask with 0xFF
        return f'{val & 0xFF:02x}'
    else:  # 32 bits
        # For int32, mask with 0xFFFFFFFF
        return f'{val & 0xFFFFFFFF:08x}'

def manual_convolution(input_int8, weights_int8, bias_int32):
    """
    Perform manual convolution to get exact int32 accumulator values
    WITHOUT ReLU activation
    """
    batch, in_h, in_w, in_c = input_int8.shape
    out_c, k_h, k_w, k_c = weights_int8.shape

    stride = 1
    out_h = (in_h - k_h) // stride + 1
    out_w = (in_w - k_w) // stride + 1

    output_int32 = np.zeros((batch, out_h, out_w, out_c), dtype=np.int32)

    for b in range(batch):
        for oc in range(out_c):
            for oh in range(out_h):
                for ow in range(out_w):
                    acc = 0
                    for kh in range(k_h):
                        for kw in range(k_w):
                            for ic in range(in_c):
                                ih = oh * stride + kh
                                iw = ow * stride + kw
                                acc += int(input_int8[b, ih, iw, ic]) * int(weights_int8[oc, kh, kw, ic])
                    output_int32[b, oh, ow, oc] = acc + bias_int32[oc]

    return output_int32

def main():
    # Configuration
    model_path = 'lenet5_int8 (1).tflite'
    image_path = 'R.png'
    output_dir = 'hw_verification'

    print("="*60)
    print("Simplified Hardware Verification Data Export")
    print("CONVOLUTION + BIAS ONLY (NO ReLU)")
    print("="*60)

    # Create output directory
    os.makedirs(output_dir, exist_ok=True)

    # Load model
    interpreter = Interpreter(model_path)
    interpreter.allocate_tensors()

    # Get input details
    input_details = interpreter.get_input_details()[0]
    input_scale = input_details['quantization'][0]
    input_zp = input_details['quantization'][1]

    # Load and quantize image
    img_array = load_and_preprocess_image(image_path)
    quantized_input = np.round(img_array / input_scale) + input_zp
    quantized_input = np.clip(quantized_input, -128, 127).astype(np.int8)

    # Extract weights and bias
    tensor_details = interpreter.get_tensor_details()

    weights_int8 = None
    bias_int32 = None

    for tensor in tensor_details:
        name = tensor['name']
        if 'pseudo_qconst9' in name:  # conv1 weights
            weights_int8 = interpreter.get_tensor(tensor['index'])
        elif 'pseudo_qconst8' in name:  # conv1 bias
            bias_int32 = interpreter.get_tensor(tensor['index'])

    if weights_int8 is None or bias_int32 is None:
        print("ERROR: Could not find weights or bias")
        return

    print(f"\nData loaded:")
    print(f"  Input shape: {quantized_input.shape}")
    print(f"  Weights shape: {weights_int8.shape}")
    print(f"  Bias shape: {bias_int32.shape}")

    # Perform convolution
    print("\nPerforming convolution + bias (NO ReLU)...")
    int32_output = manual_convolution(quantized_input, weights_int8, bias_int32)

    print(f"  Output shape: {int32_output.shape}")
    print(f"  Output range: [{int32_output.min()}, {int32_output.max()}]")
    print(f"  Negative values: {np.sum(int32_output < 0)}/{int32_output.size}")

    # Write input file (int8 hex)
    print(f"\nWriting input1.mem...")
    with open(os.path.join(output_dir, 'input13.mem'), 'w') as f:
        for val in quantized_input.flatten():
            # Convert to unsigned int first, then to hex
            unsigned_val = val.astype(np.uint8)
            f.write(f'{unsigned_val:02x}\n')

    # Write weights file (int8 hex)
    print(f"Writing conv1_weights.mem...")
    with open(os.path.join(output_dir, 'conv1_weights2.mem'), 'w') as f:
        for val in weights_int8.flatten():
            unsigned_val = val.astype(np.uint8)
            f.write(f'{unsigned_val:02x}\n')

    # Write bias file (int32 hex)
    print(f"Writing conv1_bias.mem...")
    with open(os.path.join(output_dir, 'conv1_bias2.mem'), 'w') as f:
        for val in bias_int32:
            unsigned_val = val.astype(np.uint32)
            f.write(f'{unsigned_val:08x}\n')

    # Write output file (int32 hex, CHW order)
    print(f"Writing conv1_output1_int32.mem...")
    output_flat = int32_output[0]  # Remove batch dimension
    output_flat = np.transpose(output_flat, (2, 0, 1))  # [H,W,C] -> [C,H,W]

    with open(os.path.join(output_dir, 'conv1_output14_int32t.mem'), 'w') as f:
        for val in output_flat.flatten():
            unsigned_val = val.astype(np.uint32)
            f.write(f'{unsigned_val:08x}\n')

    # Summary
    print("\n" + "="*60)
    print("SUMMARY")
    print("="*60)
    print(f"Input values: {quantized_input.size}")
    print(f"Weight values: {weights_int8.size}")
    print(f"Bias values: {bias_int32.size}")
    print(f"Output values: {output_flat.size}")
    print(f"\nOutput shape: [C={output_flat.shape[0]}, H={output_flat.shape[1]}, W={output_flat.shape[2]}]")
    print(f"Files saved in: {os.path.abspath(output_dir)}")

    # Show sample values
    print("\n" + "="*60)
    print("SAMPLE VALUES")
    print("="*60)

    # First 5 input values
    print("\nFirst 5 input values:")
    for i in range(5):
        val = quantized_input.flatten()[i]
        hex_val = f'{val.astype(np.uint8):02x}'
        print(f"  input[{i}] = {val:4d} (0x{hex_val})")

    # First 5 weight values
    print("\nFirst 5 weight values:")
    for i in range(5):
        val = weights_int8.flatten()[i]
        hex_val = f'{val.astype(np.uint8):02x}'
        print(f"  weight[{i}] = {val:4d} (0x{hex_val})")

    # All bias values
    print("\nAll bias values:")
    for i in range(len(bias_int32)):
        val = bias_int32[i]
        hex_val = f'{val.astype(np.uint32):08x}'
        print(f"  bias[{i}] = {val:8d} (0x{hex_val})")

    # First 5 output values
    print("\nFirst 5 output values (channel 0):")
    for i in range(5):
        val = output_flat.flatten()[i]
        hex_val = f'{val.astype(np.uint32):08x}'
        print(f"  output[{i}] = {val:8d} (0x{hex_val})")

if _name_ == '_main_':
    main()