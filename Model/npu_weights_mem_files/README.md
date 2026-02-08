# NPU Weight and Bias Memory Files

## Overview
This directory contains extracted weights and biases from the quantized LeNet-5 model for NPU deployment.

## Files Generated
- **Weights**: 5 INT8 weight files
- **Biases**: 5 INT32 bias files
- **Metadata**: extraction_metadata.json

## Weight Files (INT8)
Format: Hexadecimal, 2 digits per weight (00-FF)
Each line contains one weight value
Encoding: Signed INT8 (-128 to 127) → Unsigned HEX (00 to FF)

Files:
- weights_dense1_int8.mem: 840 weights, shape [10, 84]
- weights_dense2_int8.mem: 10,080 weights, shape [84, 120]
- weights_dense3_int8.mem: 30,720 weights, shape [120, 256]
- weights_conv1_int8.mem: 2,400 weights, shape [16, 5, 5, 6]
- weights_conv2_int8.mem: 150 weights, shape [6, 5, 5, 1]

Total weight parameters: 44,190

## Bias Files (INT32)
Format: Hexadecimal, 8 digits per bias
Each line contains one bias value (32-bit signed integer)
Scaling: Original FP32 bias × 2^16 (Q16.16 fixed-point format)

Files:
- bias_conv1_int32.mem: 6 biases
- bias_conv2_int32.mem: 16 biases
- bias_dense1_int32.mem: 120 biases
- bias_dense2_int32.mem: 84 biases
- bias_dense3_int32.mem: 10 biases

Total bias parameters: 236

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
- Total weight parameters: 44,190
- Total bias parameters: 236
- Total INT8 weights: 5 layers
- Total INT32 biases: 5 layers

## Important Notes
- Weights are quantized INT8 values from the TFLite model
- Biases are INT32 fixed-point (FP32 × 2^16 for precision)
- All values stored as hexadecimal, one per line
- Bias scaling factor (2^16) ensures precision preservation
- See extraction_metadata.json for detailed layer information
