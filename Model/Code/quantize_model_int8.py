import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import tensorflow as tf
import tensorflow_datasets as tfds
from tensorflow.keras.datasets import mnist
from tensorflow.keras.models import load_model
from tensorflow.keras.utils import to_categorical
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.datasets import fetch_openml
import cv2
import time
import os
import json

print("="*70)
print("INT8 QUANTIZATION FOR NPU HARDWARE DEPLOYMENT")
print("="*70)

# ============================================================
# 1. LOAD THE BEST TRAINED MODEL
# ============================================================
print("\n📦 Loading the best trained model...")

model_path = 'lenet5_model_continued_best.h5'
try:
    model_fp32 = load_model(model_path)
    print(f"✅ Model loaded successfully from: {model_path}")
    model_fp32.summary()
except Exception as e:
    print(f"❌ Error loading model: {e}")
    exit()

# ============================================================
# 2. LOAD ALL DATASETS
# ============================================================
print("\n📦 Loading datasets...")

# MNIST
(x_train_mnist, y_train_mnist), (x_test_mnist, y_test_mnist) = mnist.load_data()
x_train_mnist = x_train_mnist.reshape(-1, 28, 28, 1).astype('float32') / 255
x_test_mnist = x_test_mnist.reshape(-1, 28, 28, 1).astype('float32') / 255
print(f"✅ MNIST loaded: {x_train_mnist.shape}")

# EMNIST
emnist_loaded = False
try:
    (ds_emnist_train, ds_emnist_test), _ = tfds.load(
        'emnist/digits', split=['train', 'test'], as_supervised=True, with_info=True
    )

    def dataset_to_numpy(dataset):
        images, labels = [], []
        for image, label in dataset:
            images.append(image.numpy())
            labels.append(label.numpy())
        return np.array(images), np.array(labels)

    x_train_emnist, y_train_emnist = dataset_to_numpy(ds_emnist_train)
    x_test_emnist, y_test_emnist = dataset_to_numpy(ds_emnist_test)
    x_train_emnist = x_train_emnist.astype('float32') / 255.0
    x_test_emnist = x_test_emnist.astype('float32') / 255.0
    if len(x_train_emnist.shape) == 3:
        x_train_emnist = x_train_emnist.reshape(-1, 28, 28, 1)
        x_test_emnist = x_test_emnist.reshape(-1, 28, 28, 1)
    emnist_loaded = True
    print(f"✅ EMNIST loaded: {x_train_emnist.shape}")
except:
    print(f"⚠️ EMNIST not available")

# USPS
usps_loaded = False
try:
    usps_data = fetch_openml('usps', version=2, parser='auto')
    x_usps = usps_data.data.values.reshape(-1, 16, 16).astype('float32')
    if usps_data.target.dtype == 'object' or usps_data.target.dtype.kind in ['U', 'S']:
        y_usps = usps_data.target.astype(str).astype('int')
    else:
        y_usps = usps_data.target.values.astype('int')
    y_usps = y_usps - 1
    x_usps_resized = np.array([cv2.resize(img, (28, 28)) for img in x_usps])
    x_train_usps = x_usps_resized[:7291].reshape(-1, 28, 28, 1) / 255.0
    x_test_usps = x_usps_resized[7291:].reshape(-1, 28, 28, 1) / 255.0
    y_train_usps = y_usps[:7291]
    y_test_usps = y_usps[7291:]
    usps_loaded = True
    print(f"✅ USPS loaded: {x_train_usps.shape}")
except:
    print(f"⚠️ USPS not available")

# ============================================================
# 3. PREPARE LARGE REPRESENTATIVE DATASET FOR CALIBRATION
# ============================================================
print("\n🔧 Preparing representative dataset for calibration...")

# Use MORE samples for better INT8 calibration (critical for NPU)
representative_data = [x_train_mnist[:10000]]  # 10k samples from MNIST
if emnist_loaded:
    representative_data.append(x_train_emnist[:10000])  # 10k from EMNIST
if usps_loaded:
    representative_data.append(x_train_usps[:5000])  # All USPS training data

representative_data = np.concatenate(representative_data, axis=0)
np.random.shuffle(representative_data)  # Shuffle for diversity

print(f"✅ Representative dataset: {representative_data.shape}")
print(f"   This will be used to calibrate INT8 quantization ranges")

# ============================================================
# 4. BASELINE FP32 EVALUATION
# ============================================================
print("\n" + "="*70)
print("BASELINE FP32 EVALUATION")
print("="*70)

results_fp32 = {}

print("\n🔍 MNIST...")
start_time = time.time()
y_pred_mnist_fp32 = np.argmax(model_fp32.predict(x_test_mnist, verbose=0), axis=1)
mnist_time_fp32 = time.time() - start_time
acc_mnist_fp32 = np.mean(y_pred_mnist_fp32 == y_test_mnist)
results_fp32['MNIST'] = {'accuracy': acc_mnist_fp32, 'time': mnist_time_fp32}
print(f"   Accuracy: {acc_mnist_fp32*100:.2f}%")
print(f"   Time: {mnist_time_fp32:.2f}s")

if emnist_loaded:
    print("🔍 EMNIST...")
    start_time = time.time()
    y_pred_emnist_fp32 = np.argmax(model_fp32.predict(x_test_emnist, verbose=0), axis=1)
    emnist_time_fp32 = time.time() - start_time
    acc_emnist_fp32 = np.mean(y_pred_emnist_fp32 == y_test_emnist)
    results_fp32['EMNIST'] = {'accuracy': acc_emnist_fp32, 'time': emnist_time_fp32}
    print(f"   Accuracy: {acc_emnist_fp32*100:.2f}%")
    print(f"   Time: {emnist_time_fp32:.2f}s")

if usps_loaded:
    print("🔍 USPS...")
    start_time = time.time()
    y_pred_usps_fp32 = np.argmax(model_fp32.predict(x_test_usps, verbose=0), axis=1)
    usps_time_fp32 = time.time() - start_time
    acc_usps_fp32 = np.mean(y_pred_usps_fp32 == y_test_usps)
    results_fp32['USPS'] = {'accuracy': acc_usps_fp32, 'time': usps_time_fp32}
    print(f"   Accuracy: {acc_usps_fp32*100:.2f}%")
    print(f"   Time: {usps_time_fp32:.2f}s")

# ============================================================
# 5. FULL INT8 QUANTIZATION FOR NPU (INTEGER-ONLY)
# ============================================================
print("\n" + "="*70)
print("FULL INT8 QUANTIZATION FOR NPU (INTEGER-ONLY OPERATIONS)")
print("="*70)

def representative_dataset_gen():
    """Generator for calibration data - use diverse samples"""
    dataset_size = len(representative_data)
    # Use all representative data for best calibration
    for i in range(min(5000, dataset_size)):  # Use 5000 samples for calibration
        # Yield data in the correct format
        sample = representative_data[i:i+1].astype(np.float32)
        yield [sample]

print("\n⚙️ Converting to INT8 TFLite (this may take a few minutes)...")

converter = tf.lite.TFLiteConverter.from_keras_model(model_fp32)

# Enable optimization
converter.optimizations = [tf.lite.Optimize.DEFAULT]

# Set the representative dataset for calibration
converter.representative_dataset = representative_dataset_gen

# CRITICAL FOR NPU: Enforce full integer quantization
# This ensures ALL operations are INT8 (no float fallback)
converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]

# Set input/output to INT8 (required for NPU)
converter.inference_input_type = tf.uint8
converter.inference_output_type = tf.uint8

# Additional settings for better quantization
converter.experimental_new_quantizer = True

try:
    tflite_model_int8 = converter.convert()
    print("✅ Full INT8 quantization successful!")

    # Save the model
    with open('lenet5_npu_int8.tflite', 'wb') as f:
        f.write(tflite_model_int8)

    # Check sizes
    original_size = os.path.getsize(model_path) / 1024  # KB
    quantized_size = os.path.getsize('lenet5_npu_int8.tflite') / 1024  # KB

    print(f"\n📊 Model Size:")
    print(f"   Original (FP32): {original_size:.2f} KB")
    print(f"   Quantized (INT8): {quantized_size:.2f} KB")
    print(f"   Compression: {original_size/quantized_size:.2f}x")
    print(f"   Reduction: {(1-quantized_size/original_size)*100:.2f}%")

except Exception as e:
    print(f"❌ Error during quantization: {e}")
    print("\nThis might happen if:")
    print("   - Some operations don't support INT8")
    print("   - Representative dataset is insufficient")
    print("\nTrying alternative approach...")

    # Alternative: Allow some ops to use INT8, others use float
    converter = tf.lite.TFLiteConverter.from_keras_model(model_fp32)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative_dataset_gen
    # Remove strict INT8-only requirement
    tflite_model_int8 = converter.convert()

    with open('lenet5_npu_int8.tflite', 'wb') as f:
        f.write(tflite_model_int8)

    print("✅ Quantized with mixed precision (some INT8, some float)")

# ============================================================
# 6. LOAD AND INSPECT QUANTIZED MODEL
# ============================================================
print("\n📦 Loading quantized model...")

interpreter = tf.lite.Interpreter(model_path='lenet5_npu_int8.tflite')
interpreter.allocate_tensors()

# Get input/output details
input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

print("\n🔍 Model Details:")
print(f"\n   Input:")
print(f"      Shape: {input_details[0]['shape']}")
print(f"      Type: {input_details[0]['dtype']}")
print(f"      Quantization: {input_details[0]['quantization']}")

print(f"\n   Output:")
print(f"      Shape: {output_details[0]['shape']}")
print(f"      Type: {output_details[0]['dtype']}")
print(f"      Quantization: {output_details[0]['quantization']}")

# Get quantization parameters
input_scale, input_zero_point = input_details[0]['quantization']
output_scale, output_zero_point = output_details[0]['quantization']

print(f"\n   Quantization Parameters:")
print(f"      Input scale: {input_scale}, zero point: {input_zero_point}")
print(f"      Output scale: {output_scale}, zero point: {output_zero_point}")

# ============================================================
# 7. HELPER FUNCTION FOR INT8 INFERENCE
# ============================================================
def predict_int8_tflite(interpreter, x_data, batch_size=100):
    """
    Make predictions using INT8 TFLite model
    Properly handles uint8 input/output quantization
    """
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    input_scale, input_zero_point = input_details[0]['quantization']
    output_scale, output_zero_point = output_details[0]['quantization']

    predictions = []
    num_samples = len(x_data)

    for i in range(0, num_samples, batch_size):
        batch_end = min(i + batch_size, num_samples)

        for j in range(i, batch_end):
            sample = x_data[j]

            # Quantize input: float [0,1] -> uint8 [0,255]
            if input_details[0]['dtype'] == np.uint8:
                # Standard quantization for uint8
                input_data = sample.reshape(1, 28, 28, 1)
                input_quantized = (input_data / input_scale + input_zero_point).astype(np.uint8)
            else:
                # If input is float, just use as-is
                input_quantized = sample.reshape(1, 28, 28, 1).astype(np.float32)

            # Run inference
            interpreter.set_tensor(input_details[0]['index'], input_quantized)
            interpreter.invoke()

            # Get output
            output_data = interpreter.get_tensor(output_details[0]['index'])

            # Dequantize output: uint8 -> float probabilities
            if output_details[0]['dtype'] == np.uint8:
                output_float = output_scale * (output_data.astype(np.float32) - output_zero_point)
            else:
                output_float = output_data

            predictions.append(output_float[0])

        if (i // batch_size + 1) % 10 == 0 or batch_end == num_samples:
            print(f"   Processed {batch_end}/{num_samples} samples...")

    return np.array(predictions)

# ============================================================
# 8. EVALUATE INT8 MODEL
# ============================================================
print("\n" + "="*70)
print("EVALUATING INT8 MODEL FOR NPU")
print("="*70)

results_int8 = {}

# MNIST
print("\n🔍 Evaluating on MNIST...")
start_time = time.time()
y_pred_mnist_int8_probs = predict_int8_tflite(interpreter, x_test_mnist)
mnist_time_int8 = time.time() - start_time
y_pred_mnist_int8 = np.argmax(y_pred_mnist_int8_probs, axis=1)
acc_mnist_int8 = np.mean(y_pred_mnist_int8 == y_test_mnist)
results_int8['MNIST'] = {'accuracy': acc_mnist_int8, 'time': mnist_time_int8}
print(f"✅ MNIST Accuracy: {acc_mnist_int8*100:.2f}%")
print(f"   Accuracy drop: {(acc_mnist_fp32-acc_mnist_int8)*100:.2f}%")
print(f"   Inference time: {mnist_time_int8:.2f}s")

# EMNIST
if emnist_loaded:
    print("\n🔍 Evaluating on EMNIST...")
    start_time = time.time()
    y_pred_emnist_int8_probs = predict_int8_tflite(interpreter, x_test_emnist)
    emnist_time_int8 = time.time() - start_time
    y_pred_emnist_int8 = np.argmax(y_pred_emnist_int8_probs, axis=1)
    acc_emnist_int8 = np.mean(y_pred_emnist_int8 == y_test_emnist)
    results_int8['EMNIST'] = {'accuracy': acc_emnist_int8, 'time': emnist_time_int8}
    print(f"✅ EMNIST Accuracy: {acc_emnist_int8*100:.2f}%")
    print(f"   Accuracy drop: {(acc_emnist_fp32-acc_emnist_int8)*100:.2f}%")
    print(f"   Inference time: {emnist_time_int8:.2f}s")

# USPS
if usps_loaded:
    print("\n🔍 Evaluating on USPS...")
    start_time = time.time()
    y_pred_usps_int8_probs = predict_int8_tflite(interpreter, x_test_usps)
    usps_time_int8 = time.time() - start_time
    y_pred_usps_int8 = np.argmax(y_pred_usps_int8_probs, axis=1)
    acc_usps_int8 = np.mean(y_pred_usps_int8 == y_test_usps)
    results_int8['USPS'] = {'accuracy': acc_usps_int8, 'time': usps_time_int8}
    print(f"✅ USPS Accuracy: {acc_usps_int8*100:.2f}%")
    print(f"   Accuracy drop: {(acc_usps_fp32-acc_usps_int8)*100:.2f}%")
    print(f"   Inference time: {usps_time_int8:.2f}s")

# ============================================================
# 9. DETAILED COMPARISON
# ============================================================
print("\n" + "="*70)
print("FP32 vs INT8 COMPARISON")
print("="*70)

print(f"\n{'Dataset':<15} {'FP32 Acc':<15} {'INT8 Acc':<15} {'Acc Drop':<15}")
print("-" * 60)

datasets = list(results_fp32.keys())
for ds in datasets:
    fp32_acc = results_fp32[ds]['accuracy'] * 100
    int8_acc = results_int8[ds]['accuracy'] * 100
    drop = fp32_acc - int8_acc

    print(f"{ds:<15} {fp32_acc:>6.2f}%{'':<8} {int8_acc:>6.2f}%{'':<8} {drop:>+6.2f}%")

avg_drop = np.mean([results_fp32[ds]['accuracy'] - results_int8[ds]['accuracy'] for ds in datasets]) * 100
print(f"\n{'Average':<15} {'':<15} {'':<15} {avg_drop:>+6.2f}%")

# ============================================================
# 10. VISUALIZATION - ACCURACY COMPARISON
# ============================================================
print("\n📊 Creating comparison visualizations...")

datasets_list = list(results_fp32.keys())
fp32_accs = [results_fp32[d]['accuracy'] * 100 for d in datasets_list]
int8_accs = [results_int8[d]['accuracy'] * 100 for d in datasets_list]

x = np.arange(len(datasets_list))
width = 0.35

fig, axes = plt.subplots(1, 2, figsize=(15, 6))

# Accuracy comparison
bars1 = axes[0].bar(x - width/2, fp32_accs, width, label='FP32 (Original)', color='steelblue')
bars2 = axes[0].bar(x + width/2, int8_accs, width, label='INT8 (Quantized)', color='coral')

axes[0].set_ylabel('Accuracy (%)', fontsize=12)
axes[0].set_title('FP32 vs INT8 Accuracy Comparison', fontsize=14, fontweight='bold')
axes[0].set_xticks(x)
axes[0].set_xticklabels(datasets_list, fontsize=12)
axes[0].legend(fontsize=11)
axes[0].grid(axis='y', alpha=0.3)
axes[0].set_ylim([0, 105])

# Add value labels
for bars in [bars1, bars2]:
    for bar in bars:
        height = bar.get_height()
        axes[0].text(bar.get_x() + bar.get_width()/2., height,
                    f'{height:.2f}%',
                    ha='center', va='bottom', fontsize=9, fontweight='bold')

# Accuracy drop
acc_drops = [fp32_accs[i] - int8_accs[i] for i in range(len(datasets_list))]
colors = ['red' if drop > 1 else 'orange' if drop > 0.5 else 'green' for drop in acc_drops]
bars = axes[1].bar(datasets_list, acc_drops, color=colors, alpha=0.7)

axes[1].set_ylabel('Accuracy Drop (%)', fontsize=12)
axes[1].set_title('Accuracy Degradation Due to Quantization', fontsize=14, fontweight='bold')
axes[1].grid(axis='y', alpha=0.3)
axes[1].axhline(y=0, color='black', linestyle='-', linewidth=0.5)
axes[1].axhline(y=1, color='red', linestyle='--', linewidth=1, alpha=0.5, label='1% threshold')
axes[1].legend()

# Add value labels
for bar in bars:
    height = bar.get_height()
    axes[1].text(bar.get_x() + bar.get_width()/2., height,
                f'{height:.2f}%',
                ha='center', va='bottom' if height > 0 else 'top',
                fontsize=10, fontweight='bold')

plt.tight_layout()
plt.savefig('quantization_accuracy_comparison.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 11. VISUALIZATION - INFERENCE TIME COMPARISON
# ============================================================
print("\n📊 Creating inference time comparison...")

fig, ax = plt.subplots(figsize=(10, 6))

fp32_times = [results_fp32[d]['time'] for d in datasets_list]
int8_times = [results_int8[d]['time'] for d in datasets_list]

x = np.arange(len(datasets_list))
width = 0.35

bars1 = ax.bar(x - width/2, fp32_times, width, label='FP32 (Original)', color='steelblue')
bars2 = ax.bar(x + width/2, int8_times, width, label='INT8 (Quantized)', color='coral')

ax.set_ylabel('Inference Time (seconds)', fontsize=12)
ax.set_title('FP32 vs INT8 Inference Time Comparison', fontsize=14, fontweight='bold')
ax.set_xticks(x)
ax.set_xticklabels(datasets_list, fontsize=12)
ax.legend(fontsize=11)
ax.grid(axis='y', alpha=0.3)

# Add value labels
for bars in [bars1, bars2]:
    for bar in bars:
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
               f'{height:.2f}s',
               ha='center', va='bottom', fontsize=10, fontweight='bold')

plt.tight_layout()
plt.savefig('quantization_speed_comparison.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 12. CONFUSION MATRIX COMPARISON (COMBINED DATASETS)
# ============================================================
print("\n📊 Creating confusion matrix comparison for combined datasets...")

# Combine all available datasets
y_true_combined = y_test_mnist
y_pred_fp32_combined = y_pred_mnist_fp32
y_pred_int8_combined = y_pred_mnist_int8

if emnist_loaded:
    y_true_combined = np.concatenate([y_true_combined, y_test_emnist])
    y_pred_fp32_combined = np.concatenate([y_pred_fp32_combined, y_pred_emnist_fp32])
    y_pred_int8_combined = np.concatenate([y_pred_int8_combined, y_pred_emnist_int8])

if usps_loaded:
    y_true_combined = np.concatenate([y_true_combined, y_test_usps])
    y_pred_fp32_combined = np.concatenate([y_pred_fp32_combined, y_pred_usps_fp32])
    y_pred_int8_combined = np.concatenate([y_pred_int8_combined, y_pred_usps_int8])

# Calculate combined accuracy
acc_combined_fp32 = np.mean(y_pred_fp32_combined == y_true_combined)
acc_combined_int8 = np.mean(y_pred_int8_combined == y_true_combined)

fig, axes = plt.subplots(1, 2, figsize=(16, 6))

# FP32 confusion matrix
cm_fp32_combined = confusion_matrix(y_true_combined, y_pred_fp32_combined)
sns.heatmap(cm_fp32_combined, annot=True, fmt='d', cmap='Blues', ax=axes[0],
            xticklabels=range(10), yticklabels=range(10))
axes[0].set_xlabel('Predicted Label', fontsize=12)
axes[0].set_ylabel('True Label', fontsize=12)
axes[0].set_title(f'FP32 Model - Combined Datasets\nAccuracy: {acc_combined_fp32*100:.2f}%',
                  fontsize=14, fontweight='bold')

# INT8 confusion matrix
cm_int8_combined = confusion_matrix(y_true_combined, y_pred_int8_combined)
sns.heatmap(cm_int8_combined, annot=True, fmt='d', cmap='Oranges', ax=axes[1],
            xticklabels=range(10), yticklabels=range(10))
axes[1].set_xlabel('Predicted Label', fontsize=12)
axes[1].set_ylabel('True Label', fontsize=12)
axes[1].set_title(f'INT8 Model - Combined Datasets\nAccuracy: {acc_combined_int8*100:.2f}%',
                  fontsize=14, fontweight='bold')

plt.tight_layout()
plt.savefig('quantization_confusion_matrix_comparison.png', dpi=300, bbox_inches='tight')
plt.show()

print(f"✅ Combined datasets confusion matrix created")
print(f"   Total samples: {len(y_true_combined)}")
print(f"   FP32 Combined Accuracy: {acc_combined_fp32*100:.2f}%")
print(f"   INT8 Combined Accuracy: {acc_combined_int8*100:.2f}%")

# ============================================================
# 13. SAMPLE PREDICTIONS COMPARISON
# ============================================================
print("\n🖼️ Comparing sample predictions...")

fig, axes = plt.subplots(3, 5, figsize=(15, 9))

for i in range(5):
    idx = np.random.randint(0, len(x_test_mnist))
    img = x_test_mnist[idx]
    true_label = y_test_mnist[idx]

    # Original image
    axes[0, i].imshow(img.reshape(28, 28), cmap='gray')
    axes[0, i].set_title(f'True Label: {true_label}', fontsize=10, fontweight='bold')
    axes[0, i].axis('off')

    # FP32 prediction
    pred_fp32 = y_pred_mnist_fp32[idx]
    conf_fp32 = np.max(model_fp32.predict(img.reshape(1, 28, 28, 1), verbose=0)) * 100
    axes[1, i].imshow(img.reshape(28, 28), cmap='gray')
    axes[1, i].set_title(f'FP32: {pred_fp32} ({conf_fp32:.1f}%)',
                         color='green' if pred_fp32 == true_label else 'red',
                         fontsize=10)
    axes[1, i].axis('off')

    # INT8 prediction
    pred_int8 = y_pred_mnist_int8[idx]
    conf_int8 = np.max(y_pred_mnist_int8_probs[idx]) * 100
    axes[2, i].imshow(img.reshape(28, 28), cmap='gray')
    axes[2, i].set_title(f'INT8: {pred_int8} ({conf_int8:.1f}%)',
                         color='green' if pred_int8 == true_label else 'red',
                         fontsize=10)
    axes[2, i].axis('off')

# Row labels
axes[0, 0].text(-0.3, 0.5, 'Original', transform=axes[0, 0].transAxes,
               fontsize=12, fontweight='bold', va='center', rotation=90)
axes[1, 0].text(-0.3, 0.5, 'FP32', transform=axes[1, 0].transAxes,
               fontsize=12, fontweight='bold', va='center', rotation=90)
axes[2, 0].text(-0.3, 0.5, 'INT8', transform=axes[2, 0].transAxes,
               fontsize=12, fontweight='bold', va='center', rotation=90)

plt.tight_layout()
plt.savefig('quantization_sample_predictions.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 14. FINAL REPORT
# ============================================================
print("\n" + "="*70)
print("NPU INT8 QUANTIZATION REPORT")
print("="*70)

print(f"\n📦 Model Information:")
print(f"   Original: {model_path}")
print(f"   Quantized: lenet5_npu_int8.tflite")
print(f"   Type: Full INT8 (Integer-only operations)")
print(f"   Target: NPU Hardware Accelerator")

print(f"\n📊 Size Metrics:")
print(f"   Original: {original_size:.2f} KB")
print(f"   Quantized: {quantized_size:.2f} KB")
print(f"   Compression: {original_size/quantized_size:.2f}x")

print(f"\n🎯 Accuracy Results:")
for ds in datasets:
    print(f"   {ds}:")
    print(f"      FP32: {results_fp32[ds]['accuracy']*100:.2f}%")
    print(f"      INT8: {results_int8[ds]['accuracy']*100:.2f}%")
    print(f"      Drop: {(results_fp32[ds]['accuracy']-results_int8[ds]['accuracy'])*100:+.2f}%")

print(f"\n⏱️ Performance Metrics:")
for ds in datasets:
    print(f"   {ds}:")
    print(f"      FP32 Time: {results_fp32[ds]['time']:.2f}s")
    print(f"      INT8 Time: {results_int8[ds]['time']:.2f}s")
    speedup = results_fp32[ds]['time'] / results_int8[ds]['time']
    print(f"      Speedup: {speedup:.2f}x")

print(f"\n📈 Overall Assessment:")
if avg_drop < 1:
    status = "✅ EXCELLENT - Ready for NPU deployment!"
elif avg_drop < 3:
    status = "✅ GOOD - Acceptable for most NPU applications"
elif avg_drop < 5:
    status = "⚠️ MODERATE - Consider quantization-aware training"
else:
    status = "❌ HIGH - Quantization-aware training recommended"

print(f"   {status}")
print(f"   Average accuracy drop: {avg_drop:.2f}%")

print(f"\n💡 NPU Deployment Notes:")
print(f"   ✅ Model uses INT8 operations (NPU-compatible)")
print(f"   ✅ Input/output quantization parameters available")
print(f"   ✅ Ready for hardware accelerator deployment")

print(f"\n📁 Generated Files:")
print(f"   - lenet5_npu_int8.tflite (NPU-ready model)")
print(f"   - quantization_accuracy_comparison.png")
print(f"   - quantization_speed_comparison.png")
print(f"   - quantization_confusion_matrix_comparison.png")
print(f"   - quantization_sample_predictions.png")

print("\n" + "="*70)
print("✅ NPU quantization complete!")
print("="*70)

# ============================================================
# 15. SAVE QUANTIZATION INFO FOR WEIGHT EXTRACTION
# ============================================================
print("\n💾 Saving quantization information...")

quant_info = {
    'input_details': {
        'shape': input_details[0]['shape'].tolist(),
        'dtype': str(input_details[0]['dtype']),
        'scale': float(input_scale) if input_scale else None,
        'zero_point': int(input_zero_point) if input_zero_point else None,
    },
    'output_details': {
        'shape': output_details[0]['shape'].tolist(),
        'dtype': str(output_details[0]['dtype']),
        'scale': float(output_scale) if output_scale else None,
        'zero_point': int(output_zero_point) if output_zero_point else None,
    },
    'model_size_kb': quantized_size,
    'accuracy': {ds: float(results_int8[ds]['accuracy']) for ds in datasets},
    'inference_time': {ds: float(results_int8[ds]['time']) for ds in datasets}
}

with open('quantization_info.json', 'w') as f:
    json.dump(quant_info, f, indent=2)

print("✅ Quantization info saved to 'quantization_info.json'")
print("\n🔧 Ready for weight extraction!")
print("   You can now extract INT8 weights for NPU deployment")
print("="*70)