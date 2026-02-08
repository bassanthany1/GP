import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import tensorflow as tf
import tensorflow_datasets as tfds
from tensorflow.keras.datasets import mnist
from tensorflow.keras.models import load_model
from tensorflow.keras.layers import Dropout
from tensorflow.keras.utils import to_categorical
from tensorflow.keras.callbacks import EarlyStopping, ReduceLROnPlateau, ModelCheckpoint
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.datasets import fetch_openml
import cv2
import os

print("="*70)
print("CONTINUE TRAINING MODEL A ON COMBINED DATASETS")
print("="*70)

# ============================================================
# 1. LOAD YOUR EXISTING MODEL (Model A)
# ============================================================
print("\n📦 Loading your existing Model A...")

try:
    model = load_model('lenet5_model_good.h5')
    print("✅ Model A loaded successfully!")
    print("\nModel Summary:")
    model.summary()
except Exception as e:
    print(f"❌ Error loading model: {e}")
    print("Please make sure 'lenet5_model_good.h5' exists in the current directory.")
    exit()

# ============================================================
# 2. LOAD MNIST DATASET
# ============================================================
print("\n📦 Loading MNIST dataset...")
(x_train_mnist, y_train_mnist), (x_test_mnist, y_test_mnist) = mnist.load_data()

# Normalize and reshape
x_train_mnist = x_train_mnist.reshape(-1, 28, 28, 1).astype('float32') / 255
x_test_mnist = x_test_mnist.reshape(-1, 28, 28, 1).astype('float32') / 255

print(f"MNIST - Train: {x_train_mnist.shape}, Test: {x_test_mnist.shape}")

# ============================================================
# 3. LOAD EMNIST DATASET (Digits) using TensorFlow Datasets
# ============================================================
print("\n📦 Loading EMNIST dataset...")
emnist_loaded = False

try:
    import tensorflow_datasets as tfds

    # Load EMNIST digits dataset
    (ds_emnist_train, ds_emnist_test), ds_info = tfds.load(
        'emnist/digits',
        split=['train', 'test'],
        as_supervised=True,
        with_info=True
    )

    print(f"EMNIST info: {ds_info.splits['train'].num_examples} train, {ds_info.splits['test'].num_examples} test")

    # Convert datasets to numpy arrays
    def dataset_to_numpy(dataset):
        images = []
        labels = []
        for image, label in dataset:
            images.append(image.numpy())
            labels.append(label.numpy())
        return np.array(images), np.array(labels)

    print("Converting EMNIST train dataset to numpy arrays...")
    x_train_emnist, y_train_emnist = dataset_to_numpy(ds_emnist_train)

    print("Converting EMNIST test dataset to numpy arrays...")
    x_test_emnist, y_test_emnist = dataset_to_numpy(ds_emnist_test)

    # Normalize and reshape
    x_train_emnist = x_train_emnist.astype('float32') / 255.0
    x_test_emnist = x_test_emnist.astype('float32') / 255.0

    # Ensure correct shape (28, 28, 1)
    if len(x_train_emnist.shape) == 3:
        x_train_emnist = x_train_emnist.reshape(-1, 28, 28, 1)
        x_test_emnist = x_test_emnist.reshape(-1, 28, 28, 1)

    print(f"EMNIST - Train: {x_train_emnist.shape}, Test: {x_test_emnist.shape}")
    print(f"EMNIST - Label range: {y_train_emnist.min()} to {y_train_emnist.max()}")
    emnist_loaded = True

except Exception as e:
    print(f"⚠️ Could not load EMNIST: {e}")
    print("Continuing with MNIST and USPS only...")
    print("💡 Tip: Install tensorflow-datasets with: pip install tensorflow-datasets")

# ============================================================
# 4. LOAD USPS DATASET
# ============================================================
print("\n📦 Loading USPS dataset...")
usps_loaded = False

try:
    usps_data = fetch_openml('usps', version=2, parser='auto')

    # Split into train/test
    x_usps = usps_data.data.values.reshape(-1, 16, 16).astype('float32')

    # Convert labels to integers (handle both string and numeric labels)
    if usps_data.target.dtype == 'object' or usps_data.target.dtype.kind in ['U', 'S']:
        y_usps = usps_data.target.astype(str).astype('int')
    else:
        y_usps = usps_data.target.values.astype('int')

    # CRITICAL FIX: USPS labels are 1-10, convert to 0-9
    y_usps = y_usps - 1

    # Resize USPS images from 16x16 to 28x28
    x_usps_resized = np.array([cv2.resize(img, (28, 28)) for img in x_usps])

    # Standard USPS split
    x_train_usps = x_usps_resized[:7291]
    y_train_usps = y_usps[:7291]
    x_test_usps = x_usps_resized[7291:]
    y_test_usps = y_usps[7291:]

    # Normalize
    x_train_usps = x_train_usps.reshape(-1, 28, 28, 1) / 255.0
    x_test_usps = x_test_usps.reshape(-1, 28, 28, 1) / 255.0

    print(f"USPS - Train: {x_train_usps.shape}, Test: {x_test_usps.shape}")
    print(f"USPS - Label range: {y_train_usps.min()} to {y_train_usps.max()}")
    usps_loaded = True

except Exception as e:
    print(f"⚠️ Could not load USPS: {e}")
    print("Continuing with available datasets...")

# ============================================================
# 5. COMBINE ALL DATASETS
# ============================================================
print("\n🔗 Combining datasets...")

# Combine training data
x_train_combined = [x_train_mnist]
y_train_combined = [y_train_mnist]

if emnist_loaded:
    x_train_combined.append(x_train_emnist)
    y_train_combined.append(y_train_emnist)

if usps_loaded:
    x_train_combined.append(x_train_usps)
    y_train_combined.append(y_train_usps)

x_train = np.concatenate(x_train_combined, axis=0)
y_train = np.concatenate(y_train_combined, axis=0)

# Combine test data
x_test_combined = [x_test_mnist]
y_test_combined = [y_test_mnist]

if emnist_loaded:
    x_test_combined.append(x_test_emnist)
    y_test_combined.append(y_test_emnist)

if usps_loaded:
    x_test_combined.append(x_test_usps)
    y_test_combined.append(y_test_usps)

x_test = np.concatenate(x_test_combined, axis=0)
y_test = np.concatenate(y_test_combined, axis=0)

print(f"\n✅ Combined Training Data: {x_train.shape}")
print(f"✅ Combined Test Data: {x_test.shape}")

# Shuffle the combined data
indices = np.random.permutation(len(x_train))
x_train = x_train[indices]
y_train = y_train[indices]

# Validate labels are in range [0, 9]
print(f"\n🔍 Validating labels...")
print(f"Train labels - Min: {y_train.min()}, Max: {y_train.max()}, Type: {y_train.dtype}")
print(f"Test labels - Min: {y_test.min()}, Max: {y_test.max()}, Type: {y_test.dtype}")

# Ensure labels are integers
y_train = y_train.astype('int32')
y_test = y_test.astype('int32')

# Check for invalid labels
if y_train.min() < 0 or y_train.max() > 9:
    print(f"⚠️ Warning: Train labels out of range! Filtering...")
    valid_indices = (y_train >= 0) & (y_train <= 9)
    x_train = x_train[valid_indices]
    y_train = y_train[valid_indices]
    print(f"   Filtered training data: {x_train.shape}")

if y_test.min() < 0 or y_test.max() > 9:
    print(f"⚠️ Warning: Test labels out of range! Filtering...")
    valid_indices = (y_test >= 0) & (y_test <= 9)
    x_test = x_test[valid_indices]
    y_test = y_test[valid_indices]
    print(f"   Filtered test data: {x_test.shape}")

# Convert labels to categorical
y_train_cat = to_categorical(y_train, 10)
y_test_cat = to_categorical(y_test, 10)

# ============================================================
# 6. EVALUATE MODEL A ON NEW DATASETS (BEFORE RETRAINING)
# ============================================================
print("\n" + "="*70)
print("EVALUATING MODEL A (BEFORE RETRAINING)")
print("="*70)

# Test on MNIST
y_pred_mnist_before = np.argmax(model.predict(x_test_mnist, verbose=0), axis=1)
acc_mnist_before = np.mean(y_pred_mnist_before == y_test_mnist)
print(f"\nMNIST Test Accuracy (Before): {acc_mnist_before*100:.2f}%")

# Test on USPS (if available)
if usps_loaded:
    y_pred_usps_before = np.argmax(model.predict(x_test_usps, verbose=0), axis=1)
    acc_usps_before = np.mean(y_pred_usps_before == y_test_usps)
    print(f"USPS Test Accuracy (Before): {acc_usps_before*100:.2f}%")

# Test on EMNIST (if available)
if emnist_loaded:
    y_pred_emnist_before = np.argmax(model.predict(x_test_emnist, verbose=0), axis=1)
    acc_emnist_before = np.mean(y_pred_emnist_before == y_test_emnist)
    print(f"EMNIST Test Accuracy (Before): {acc_emnist_before*100:.2f}%")

# ============================================================
# 7. SETUP DATA AUGMENTATION (REDUCED TO PREVENT OVERFITTING)
# ============================================================
print("\n🎨 Setting up data augmentation...")

datagen = ImageDataGenerator(
    rotation_range=10,           # Reduced from 15 to 10 degrees
    width_shift_range=0.08,      # Reduced from 0.1 to 0.08
    height_shift_range=0.08,     # Reduced from 0.1 to 0.08
    zoom_range=0.08,             # Reduced from 0.1 to 0.08
    shear_range=0.05,            # Reduced from 0.1 to 0.05
    fill_mode='nearest'          # Fill strategy for new pixels
)

datagen.fit(x_train)

# ============================================================
# 8. RECOMPILE MODEL WITH LOWER LEARNING RATE
# ============================================================
print("\n🔧 Recompiling model with lower learning rate for fine-tuning...")

# Use appropriate learning rate for fine-tuning
# The model already knows MNIST, we just need to adapt to new datasets
model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=1e-4),  # 0.0001 - Good for fine-tuning
    loss='categorical_crossentropy',
    metrics=['accuracy']
)

# ============================================================
# 9. SETUP CALLBACKS
# ============================================================
callbacks = [
    EarlyStopping(
        monitor='val_loss',
        patience=5,  # Stop if no improvement for 5 epochs
        restore_best_weights=True,
        verbose=1
    ),
    ReduceLROnPlateau(
        monitor='val_loss',
        factor=0.5,
        patience=4,  # Reduce LR if no improvement for 4 epochs
        min_lr=1e-7,
        verbose=1
    ),
    ModelCheckpoint(
        'lenet5_model_continued_best.h5',
        monitor='val_accuracy',
        save_best_only=True,
        verbose=1
    )
]

# ============================================================
# 10. CONTINUE TRAINING ON COMBINED DATASETS
# ============================================================
print("\n🚀 Continuing training on combined datasets with augmentation...")
print("="*70)

history = model.fit(
    datagen.flow(x_train, y_train_cat, batch_size=128),
    epochs=100,  # Sufficient with proper learning rate
    validation_data=(x_test, y_test_cat),
    callbacks=callbacks,
    verbose=1,
    steps_per_epoch=len(x_train) // 128
)

# ============================================================
# 11. SAVE FINAL MODEL
# ============================================================
model.save("lenet5_model_continued_final.h5")
print("\n💾 Model saved as 'lenet5_model_continued_final.h5'")

# ============================================================
# 12. PLOT TRAINING HISTORY
# ============================================================
print("\n📊 Plotting training history...")

fig, axes = plt.subplots(1, 2, figsize=(15, 5))

# Accuracy plot
axes[0].plot(history.history['accuracy'], label='Training Accuracy', linewidth=2)
axes[0].plot(history.history['val_accuracy'], label='Validation Accuracy', linewidth=2)
axes[0].set_xlabel('Epoch', fontsize=12)
axes[0].set_ylabel('Accuracy', fontsize=12)
axes[0].set_title('Model Accuracy over Epochs (Continued Training)', fontsize=14, fontweight='bold')
axes[0].legend(fontsize=10)
axes[0].grid(True, alpha=0.3)

# Loss plot
axes[1].plot(history.history['loss'], label='Training Loss', linewidth=2)
axes[1].plot(history.history['val_loss'], label='Validation Loss', linewidth=2)
axes[1].set_xlabel('Epoch', fontsize=12)
axes[1].set_ylabel('Loss', fontsize=12)
axes[1].set_title('Model Loss over Epochs (Continued Training)', fontsize=14, fontweight='bold')
axes[1].legend(fontsize=10)
axes[1].grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig('continued_training_history.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 13. EVALUATE MODEL AFTER RETRAINING
# ============================================================
print("\n" + "="*70)
print("EVALUATING MODEL A (AFTER RETRAINING)")
print("="*70)

# Test on MNIST
y_pred_mnist_after = np.argmax(model.predict(x_test_mnist, verbose=0), axis=1)
acc_mnist_after = np.mean(y_pred_mnist_after == y_test_mnist)
print(f"\nMNIST Test Accuracy (After): {acc_mnist_after*100:.2f}%")
print(f"  Improvement: {(acc_mnist_after - acc_mnist_before)*100:+.2f}%")

# Test on USPS (if available)
if usps_loaded:
    y_pred_usps_after = np.argmax(model.predict(x_test_usps, verbose=0), axis=1)
    acc_usps_after = np.mean(y_pred_usps_after == y_test_usps)
    print(f"\nUSPS Test Accuracy (After): {acc_usps_after*100:.2f}%")
    print(f"  Improvement: {(acc_usps_after - acc_usps_before)*100:+.2f}%")

# Test on EMNIST (if available)
if emnist_loaded:
    y_pred_emnist_after = np.argmax(model.predict(x_test_emnist, verbose=0), axis=1)
    acc_emnist_after = np.mean(y_pred_emnist_after == y_test_emnist)
    print(f"\nEMNIST Test Accuracy (After): {acc_emnist_after*100:.2f}%")
    print(f"  Improvement: {(acc_emnist_after - acc_emnist_before)*100:+.2f}%")

# Overall test accuracy
y_pred_all = np.argmax(model.predict(x_test, verbose=0), axis=1)
acc_overall = np.mean(y_pred_all == y_test)
print(f"\n✅ Overall Test Accuracy (Combined Datasets): {acc_overall*100:.2f}%")

# ============================================================
# 14. CLASSIFICATION REPORT
# ============================================================
print("\n" + "="*70)
print("CLASSIFICATION REPORT (COMBINED TEST DATA)")
print("="*70)
print(classification_report(y_test, y_pred_all))

# ============================================================
# 15. CONFUSION MATRIX
# ============================================================
cm = confusion_matrix(y_test, y_pred_all)

plt.figure(figsize=(10, 8))
sns.heatmap(cm, annot=True, fmt='d', cmap='Blues',
            xticklabels=range(10), yticklabels=range(10))
plt.xlabel('Predicted Label', fontsize=12)
plt.ylabel('True Label', fontsize=12)
plt.title('Confusion Matrix - Continued Training on Combined Datasets',
          fontsize=14, fontweight='bold')
plt.savefig('continued_confusion_matrix.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 16. BEFORE/AFTER COMPARISON VISUALIZATION
# ============================================================
print("\n📊 Creating before/after comparison...")

datasets_list = ['MNIST']
before_list = [acc_mnist_before * 100]
after_list = [acc_mnist_after * 100]

if usps_loaded:
    datasets_list.append('USPS')
    before_list.append(acc_usps_before * 100)
    after_list.append(acc_usps_after * 100)

if emnist_loaded:
    datasets_list.append('EMNIST')
    before_list.append(acc_emnist_before * 100)
    after_list.append(acc_emnist_after * 100)

x = np.arange(len(datasets_list))
width = 0.35

fig, ax = plt.subplots(figsize=(10, 6))
bars1 = ax.bar(x - width/2, before_list, width, label='Before Retraining', color='lightcoral')
bars2 = ax.bar(x + width/2, after_list, width, label='After Retraining', color='lightgreen')

ax.set_ylabel('Accuracy (%)', fontsize=12)
ax.set_title('Model A: Performance Before and After Continued Training',
             fontsize=14, fontweight='bold')
ax.set_xticks(x)
ax.set_xticklabels(datasets_list, fontsize=12)
ax.legend(fontsize=11)
ax.grid(axis='y', alpha=0.3)
ax.set_ylim([0, 105])

# Add value labels on bars
for bars in [bars1, bars2]:
    for bar in bars:
        height = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2., height,
                f'{height:.2f}%',
                ha='center', va='bottom', fontsize=10, fontweight='bold')

plt.tight_layout()
plt.savefig('before_after_comparison.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 17. SAMPLE PREDICTIONS
# ============================================================
print("\n🖼️ Testing with sample images...")

fig, axes = plt.subplots(2, 5, figsize=(15, 6))
axes = axes.ravel()

for i in range(10):
    idx = np.random.randint(0, len(x_test))
    img = x_test[idx]
    true_label = y_test[idx]

    pred_probs = model.predict(img.reshape(1, 28, 28, 1), verbose=0)
    pred_label = np.argmax(pred_probs)
    confidence = np.max(pred_probs) * 100

    axes[i].imshow(img.reshape(28, 28), cmap='gray')
    axes[i].set_title(f'True: {true_label}, Pred: {pred_label}\nConf: {confidence:.1f}%',
                      color='green' if true_label == pred_label else 'red')
    axes[i].axis('off')

plt.tight_layout()
plt.savefig('continued_sample_predictions.png', dpi=300, bbox_inches='tight')
plt.show()

# ============================================================
# 18. SUMMARY
# ============================================================
print("\n" + "="*70)
print("SUMMARY")
print("="*70)
print(f"\n{'Dataset':<15} {'Before':<15} {'After':<15} {'Improvement':<15}")
print("-"*60)
print(f"{'MNIST':<15} {acc_mnist_before*100:>6.2f}%{'':<8} {acc_mnist_after*100:>6.2f}%{'':<8} {(acc_mnist_after-acc_mnist_before)*100:>+6.2f}%")

if usps_loaded:
    print(f"{'USPS':<15} {acc_usps_before*100:>6.2f}%{'':<8} {acc_usps_after*100:>6.2f}%{'':<8} {(acc_usps_after-acc_usps_before)*100:>+6.2f}%")

if emnist_loaded:
    print(f"{'EMNIST':<15} {acc_emnist_before*100:>6.2f}%{'':<8} {acc_emnist_after*100:>6.2f}%{'':<8} {(acc_emnist_after-acc_emnist_before)*100:>+6.2f}%")

print("\n" + "="*70)
print("✅ Continued training complete!")
print("="*70)
print("\n📁 Saved files:")
print("   - lenet5_model_continued_final.h5 (final model)")
print("   - lenet5_model_continued_best.h5 (best checkpoint)")
print("   - continued_training_history.png")
print("   - continued_confusion_matrix.png")
print("   - before_after_comparison.png")
print("   - continued_sample_predictions.png")
print("\n🎯 Your model has been successfully fine-tuned on combined datasets!")
print("="*70)