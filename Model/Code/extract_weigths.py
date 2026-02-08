import numpy as np
import tensorflow as tf
from tensorflow.keras.models import load_model
import json
import os

print("="*70)
print("WEIGHT AND BIAS EXTRACTION FOR NPU DEPLOYMENT")
print("="*70)

# ============================================================
# 1. LOAD MODELS AND QUANTIZATION INFO
# ============================================================
print("\n📦 Loading models and quantization info...")

# Load original FP32 model for biases
model_path = 'lenet5_model_continued_best.h5'
try:
    model_fp32 = load_model(model_path)
    print(f"✅ FP32 model loaded from: {model_path}")
except Exception as e:
    print(f"❌ Error loading FP32 model: {e}")
    exit()

# Load quantized INT8 model
tflite_model_path = 'lenet5_npu_int8.tflite'
try:
    # Load the TFLite model as bytes
    with open(tflite_model_path, 'rb') as f:
        tflite_model = f.read()

    interpreter = tf.lite.Interpreter(model_content=tflite_model)
    interpreter.allocate_tensors()
    print(f"✅ INT8 TFLite model loaded from: {tflite_model_path}")
except Exception as e:
    print(f"❌ Error loading TFLite model: {e}")
    exit()

# Load quantization info
try:
    with open('quantization_info.json', 'r') as f:
        quant_info = json.load(f)
    print(f"✅ Quantization info loaded")
except:
    print(f"⚠️ Quantization info not found, will extract what we can")
    quant_info = None

# ============================================================
# 2. CREATE OUTPUT DIRECTORY
# ============================================================
output_dir = 'npu_weights_mem_files'
os.makedirs(output_dir, exist_ok=True)
print(f"\n📁 Output directory: {output_dir}/")

# ============================================================
# 3. EXTRACT INT8 WEIGHTS FROM QUANTIZED MODEL
# ============================================================
print("\n" + "="*70)
print("EXTRACTING INT8 WEIGHTS FROM QUANTIZED MODEL")
print("="*70)

# Get all tensor details from TFLite model
tensor_details = interpreter.get_tensor_details()

# Method 1: Extract from TFLite using proper filtering
print("\n🔍 Analyzing TFLite model structure...")

# Find weight tensors by analyzing the model
# Weights are typically stored in tensors with specific patterns
weight_tensors = []
bias_tensors_tflite = []

for tensor in tensor_details:
    name = tensor['name']
    shape = tensor['shape']

    # Weight tensors typically have 'pseudo_qconst' or similar patterns
    if 'pseudo_qconst' in name.lower():
        # Check if it's a weight (4D for conv, 2D for dense) or bias (1D)
        if len(shape) == 4 or len(shape) == 2:
            weight_tensors.append(tensor)
        elif len(shape) == 1:
            bias_tensors_tflite.append(tensor)

print(f"   Found {len(weight_tensors)} weight tensors")
print(f"   Found {len(bias_tensors_tflite)} bias tensors (from TFLite)")

# Extract weight data
weight_info = []
weight_layer_counter = {'conv': 0, 'dense': 0}

for idx, tensor in enumerate(weight_tensors):
    name = tensor['name']
    shape = tensor['shape']
    dtype = tensor['dtype']

    # Get the actual tensor data
    try:
        tensor_data = interpreter.get_tensor(tensor['index'])
    except Exception as e:
        print(f"\n⚠️ Warning: Could not extract tensor '{name}': {e}")
        continue

    # Determine layer type
    if len(shape) == 4:
        layer_type = 'conv'
        weight_layer_counter['conv'] += 1
        layer_num = weight_layer_counter['conv']
    elif len(shape) == 2:
        layer_type = 'dense'
        weight_layer_counter['dense'] += 1
        layer_num = weight_layer_counter['dense']
    else:
        layer_type = 'unknown'
        layer_num = idx + 1

    print(f"\n📊 {layer_type.upper()} Layer {layer_num}:")
    print(f"   Name: {name}")
    print(f"   Shape: {shape}")
    print(f"   Type: {dtype}")
    print(f"   Range: [{tensor_data.min()}, {tensor_data.max()}]")

    # Flatten the weights for .mem file
    weights_flat = tensor_data.flatten()

    # Create filename
    mem_filename = f"{output_dir}/weights_{layer_type}{layer_num}_int8.mem"

    # Save to .mem file (hex format)
    with open(mem_filename, 'w') as f:
        for weight in weights_flat:
            # Convert to unsigned byte representation
            if dtype == np.int8:
                # Convert signed int8 to unsigned representation
                unsigned_val = int(weight) if weight >= 0 else 256 + int(weight)
            else:
                unsigned_val = int(weight)
            f.write(f"{unsigned_val:02X}\n")

    print(f"   ✅ Saved to: {mem_filename}")
    print(f"   Total weights: {len(weights_flat)}")

    # Store info
    weight_info.append({
        'index': idx + 1,
        'layer_number': layer_num,
        'name': name,
        'type': layer_type,
        'shape': shape.tolist() if hasattr(shape, 'tolist') else list(shape),
        'dtype': str(dtype),
        'num_weights': int(len(weights_flat)),
        'filename': mem_filename,
        'min': int(tensor_data.min()),
        'max': int(tensor_data.max())
    })

# ============================================================
# 4. EXTRACT BIASES FROM ORIGINAL MODEL AS INT32
# ============================================================
print("\n" + "="*70)
print("EXTRACTING BIASES FROM ORIGINAL MODEL AS INT32")
print("="*70)

bias_info = []
bias_layer_counter = {'conv': 0, 'dense': 0}

# Get all layers from the original model
for layer_idx, layer in enumerate(model_fp32.layers):
    # Check if layer has bias
    if hasattr(layer, 'use_bias') and layer.use_bias:
        try:
            weights = layer.get_weights()
            if len(weights) >= 2:  # weights[0] = kernels, weights[1] = biases
                bias_fp32 = weights[1]

                # Determine layer type
                layer_name_lower = layer.name.lower()
                if 'conv' in layer_name_lower:
                    layer_type = 'conv'
                    bias_layer_counter['conv'] += 1
                    layer_num = bias_layer_counter['conv']
                elif 'dense' in layer_name_lower:
                    layer_type = 'dense'
                    bias_layer_counter['dense'] += 1
                    layer_num = bias_layer_counter['dense']
                else:
                    layer_type = 'unknown'
                    layer_num = layer_idx + 1

                print(f"\n📊 {layer_type.upper()} Layer {layer_num}: {layer.name}")
                print(f"   Type: {type(layer).__name__}")
                print(f"   Bias shape: {bias_fp32.shape}")
                print(f"   Bias range: [{bias_fp32.min():.6f}, {bias_fp32.max():.6f}]")

                # Convert FP32 bias to INT32
                # Scale by 2^16 for 16-bit fractional precision (Q16.16 format)
                scale_factor = 2**16
                bias_int32 = np.round(bias_fp32 * scale_factor).astype(np.int32)

                print(f"   Scale factor: {scale_factor} (2^16)")
                print(f"   INT32 range: [{bias_int32.min()}, {bias_int32.max()}]")

                # Create filename
                mem_filename = f"{output_dir}/bias_{layer_type}{layer_num}_int32.mem"

                # Flatten bias
                bias_flat = bias_int32.flatten()

                # Save to .mem file (hex format, 32-bit)
                with open(mem_filename, 'w') as f:
                    for bias in bias_flat:
                        # Convert to unsigned 32-bit representation
                        bias_val = int(bias)
                        unsigned_val = bias_val if bias_val >= 0 else 2**32 + bias_val
                        f.write(f"{unsigned_val:08X}\n")

                print(f"   ✅ Saved to: {mem_filename}")
                print(f"   Total biases: {len(bias_flat)}")

                # Store info
                bias_info.append({
                    'layer_index': layer_idx + 1,
                    'layer_number': layer_num,
                    'layer_name': layer.name,
                    'type': layer_type,
                    'shape': list(bias_fp32.shape),
                    'num_biases': int(len(bias_flat)),
                    'scale_factor': scale_factor,
                    'filename': mem_filename,
                    'fp32_min': float(bias_fp32.min()),
                    'fp32_max': float(bias_fp32.max()),
                    'int32_min': int(bias_int32.min()),
                    'int32_max': int(bias_int32.max())
                })
        except Exception as e:
            print(f"⚠️ Could not extract bias from layer {layer.name}: {e}")

# ============================================================
# 5. SAVE EXTRACTION METADATA
# ============================================================
print("\n" + "="*70)
print("SAVING EXTRACTION METADATA")
print("="*70)

metadata = {
    'source_models': {
        'fp32_model': model_path,
        'int8_model': tflite_model_path
    },
    'weights': {
        'count': len(weight_info),
        'format': 'INT8 (hex, 2 digits per weight)',
        'encoding': 'Signed int8 converted to unsigned hex (00-FF)',
        'layers': weight_info
    },
    'biases': {
        'count': len(bias_info),
        'format': 'INT32 (hex, 8 digits per bias)',
        'encoding': 'Signed int32 in Q16.16 fixed-point format',
        'scale_factor': 65536,
        'layers': bias_info
    },
    'notes': {
        'weight_format': 'Each line in weight .mem file contains one weight in hexadecimal (2 hex digits)',
        'bias_format': 'Each line in bias .mem file contains one bias in hexadecimal (8 hex digits)',
        'bias_scaling': 'Biases scaled by 2^16 for Q16.16 fixed-point representation',
        'weight_conversion': 'INT8 weights: value >= 0 → hex, value < 0 → 256 + value → hex'
    }
}

metadata_file = f"{output_dir}/extraction_metadata.json"
with open(metadata_file, 'w') as f:
    json.dump(metadata, f, indent=2)

print(f"✅ Metadata saved to: {metadata_file}")

# ============================================================
# 6. GENERATE SUMMARY REPORT
# ============================================================
print("\n" + "="*70)
print("EXTRACTION SUMMARY REPORT")
print("="*70)

print(f"\n📦 Source Models:")
print(f"   FP32 Model: {model_path}")
print(f"   INT8 Model: {tflite_model_path}")

print(f"\n⚙️ INT8 Weights Extracted:")
print(f"   Total layers: {len(weight_info)}")
total_weights = 0
for w in weight_info:
    print(f"   - {w['type'].upper()} Layer {w['layer_number']}: {w['num_weights']:,} weights")
    print(f"     Shape: {w['shape']}, File: {os.path.basename(w['filename'])}")
    total_weights += w['num_weights']
print(f"   Total parameters: {total_weights:,}")

print(f"\n⚙️ INT32 Biases Extracted:")
print(f"   Total layers: {len(bias_info)}")
total_biases = 0
for b in bias_info:
    print(f"   - {b['type'].upper()} Layer {b['layer_number']}: {b['num_biases']} biases")
    print(f"     File: {os.path.basename(b['filename'])}")
    total_biases += b['num_biases']
print(f"   Total bias parameters: {total_biases:,}")

print(f"\n📁 Output Directory: {output_dir}/")
print(f"   Total files generated: {len(weight_info) + len(bias_info) + 1}")

print(f"\n💾 File Format:")
print(f"   Weights: INT8 hexadecimal (2 digits per line, 00-FF)")
print(f"   Biases:  INT32 hexadecimal (8 digits per line)")
print(f"   Format:  One value per line")

print(f"\n📝 Usage Notes:")
print(f"   1. Weight .mem files contain quantized INT8 values")
print(f"   2. Bias .mem files contain INT32 values (FP32 × 2^16)")
print(f"   3. Each line in .mem file = one value in hexadecimal")
print(f"   4. Load these files directly into NPU memory")
print(f"   5. Conversion: INT8(-128 to 127) → HEX(00-FF)")

# ============================================================
# 7. CREATE CONVERSION EXAMPLES
# ============================================================
print("\n" + "="*70)
print("CONVERSION EXAMPLES")
print("="*70)

print("\n🔢 INT8 Weight Conversion Examples:")
print("   INT8 Value  →  HEX in .mem file")
print("   -----------     ----------------")
print("        127    →        7F")
print("         64    →        40")
print("          0    →        00")
print("        -64    →        C0")
print("       -128    →        80")

print("\n🔢 To convert back (HEX → INT8):")
print("   HEX  →  Unsigned  →  Signed INT8")
print("   7F   →     127    →      127")
print("   80   →     128    →     -128")
print("   FF   →     255    →       -1")

if len(bias_info) > 0:
    example_bias = bias_info[0]
    print(f"\n🔢 INT32 Bias Conversion Example (Layer {example_bias['layer_number']}):")
    print(f"   Original FP32: {example_bias['fp32_min']:.6f}")
    print(f"   × 2^16 = {example_bias['fp32_min'] * 65536:.2f}")
    print(f"   Rounded INT32: {example_bias['int32_min']}")
    print(f"   HEX: {example_bias['int32_min'] if example_bias['int32_min'] >= 0 else 2**32 + example_bias['int32_min']:08X}")

# ============================================================
# 8. CREATE README FILE
# ============================================================
readme_content = f"""# NPU Weight and Bias Memory Files

## Overview
This directory contains extracted weights and biases from the quantized LeNet-5 model for NPU deployment.

## Files Generated
- **Weights**: {len(weight_info)} INT8 weight files
- **Biases**: {len(bias_info)} INT32 bias files
- **Metadata**: extraction_metadata.json

## Weight Files (INT8)
Format: Hexadecimal, 2 digits per weight (00-FF)
Each line contains one weight value
Encoding: Signed INT8 (-128 to 127) → Unsigned HEX (00 to FF)

Files:
{chr(10).join(f"- {os.path.basename(w['filename'])}: {w['num_weights']:,} weights, shape {w['shape']}" for w in weight_info)}

Total weight parameters: {total_weights:,}

## Bias Files (INT32)
Format: Hexadecimal, 8 digits per bias
Each line contains one bias value (32-bit signed integer)
Scaling: Original FP32 bias × 2^16 (Q16.16 fixed-point format)

Files:
{chr(10).join(f"- {os.path.basename(b['filename'])}: {b['num_biases']} biases" for b in bias_info)}

Total bias parameters: {total_biases:,}

## How to Use

### Loading Weights (INT8)
```python
# Read INT8 weights from .mem file
with open('weights_conv1_int8.mem', 'r') as f:
    weights_hex = [line.strip() for line in f]
    weights_unsigned = [int(h, 16) for h in weights_hex]
    # Convert to signed int8
    weights_signed = [(w if w < 128 else w - 256) for w in weights_unsigned]
```

### Loading Biases (INT32)
```python
# Read INT32 biases from .mem file
with open('bias_conv1_int32.mem', 'r') as f:
    biases_hex = [line.strip() for line in f]
    biases_unsigned = [int(h, 16) for h in biases_hex]
    # Convert to signed int32
    biases_signed = [(b if b < 2**31 else b - 2**32) for b in biases_unsigned]
    # Convert back to float (if needed)
    biases_float = [b / (2**16) for b in biases_signed]
```

### NPU Integration
1. Load weight .mem files into NPU weight memory
2. Load bias .mem files into NPU bias memory
3. Configure NPU with quantization parameters from metadata
4. Run inference using INT8 operations

## Conversion Reference

### INT8 to HEX
| INT8 | HEX |
|------|-----|
| 127  | 7F  |
| 1    | 01  |
| 0    | 00  |
| -1   | FF  |
| -128 | 80  |

### HEX to INT8
```
If HEX < 80: value = HEX
If HEX >= 80: value = HEX - 256
```

## Model Architecture
- Total weight parameters: {total_weights:,}
- Total bias parameters: {total_biases:,}
- Total INT8 weights: {len(weight_info)} layers
- Total INT32 biases: {len(bias_info)} layers

## Important Notes
- Weights are quantized INT8 values from the TFLite model
- Biases are INT32 fixed-point (FP32 × 2^16 for precision)
- All values stored as hexadecimal, one per line
- Bias scaling factor (2^16) ensures precision preservation
- See extraction_metadata.json for detailed layer information

Generated: {os.popen('date').read().strip()}
"""

readme_file = f"{output_dir}/README.md"
with open(readme_file, 'w') as f:
    f.write(readme_content)

print(f"\n✅ README created: {readme_file}")

print("\n" + "="*70)
print("✅ WEIGHT AND BIAS EXTRACTION COMPLETE!")
print("="*70)
print(f"\n📂 Check the '{output_dir}/' directory for all generated files")
print(f"   - {len(weight_info)} weight .mem files")
print(f"   - {len(bias_info)} bias .mem files")
print(f"   - 1 metadata JSON file")
print(f"   - 1 README.md file")
print("="*70)