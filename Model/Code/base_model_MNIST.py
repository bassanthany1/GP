import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns
import tensorflow as tf
from tensorflow.keras.datasets import mnist
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Input, Conv2D, AveragePooling2D, Flatten, Dense
from tensorflow.keras.utils import to_categorical
from tensorflow.keras.callbacks import EarlyStopping
from sklearn.metrics import classification_report, confusion_matrix
# 1. تحميل البيانات
(x_train, y_train), (x_test, y_test) = mnist.load_data()

# 2. تجهيز البيانات
x_train = x_train.reshape(-1, 28, 28, 1).astype('float32') / 255
x_test = x_test.reshape(-1, 28, 28, 1).astype('float32') / 255
y_train_cat = to_categorical(y_train, 10)
y_test_cat = to_categorical(y_test, 10)
# 3. بناء موديل LeNet-5
model = Sequential([
    Input(shape=(28, 28, 1)),
    Conv2D(6, kernel_size=(5, 5), activation='relu'),
    AveragePooling2D(pool_size=(2, 2)),
    Conv2D(16, kernel_size=(5, 5), activation='relu'),
    AveragePooling2D(pool_size=(2, 2)),
    Flatten(),
    Dense(120, activation='relu'),
    Dense(84, activation='relu'),
    Dense(10, activation='softmax')
])
# 4. إعداد Early Stopping
early_stop = EarlyStopping(monitor='val_loss', patience=5, restore_best_weights=True)

# 5. تدريب الموديل مع Early Stopping
history = model.compile(optimizer='adamW', loss='categorical_crossentropy', metrics=['accuracy'])
history = model.fit(
    x_train, y_train_cat,
    epochs=100,
    batch_size=128,
    validation_split=0.1,
    callbacks=[early_stop],
    verbose=1
)
# 6. رسم منحنيات التدريب
plt.plot(history.history['accuracy'], label='Training Accuracy')
plt.plot(history.history['val_accuracy'], label='Validation Accuracy')
plt.xlabel('Epoch')
plt.ylabel('Accuracy')
plt.title('Accuracy over Epochs')
plt.legend()
plt.show()

plt.plot(history.history['loss'], label='Training Loss')
plt.plot(history.history['val_loss'], label='Validation Loss')
plt.xlabel('Epoch')
plt.ylabel('Loss')
plt.title('Loss over Epochs')
plt.legend()
plt.show()
# Save model
model.save("lenet5_model_good.h5")
# 7. التنبؤ وتحليل الأداء
y_pred_probs = model.predict(x_test)
y_pred = np.argmax(y_pred_probs, axis=1)

print(classification_report(y_test, y_pred))

# Accuracy للموديل الأصلي قبل الـ quantization
orig_accuracy = np.mean(y_pred == y_test)
print(f"✅ Original Keras Model Accuracy: {orig_accuracy*100:.2f}%")

cm = confusion_matrix(y_test, y_pred)
plt.figure(figsize=(10, 8))
sns.heatmap(cm, annot=True, fmt='d', cmap='Blues')
plt.xlabel('Predicted')
plt.ylabel('Actual')
plt.title('Confusion Matrix for LeNet-5 on MNIST')
plt.show()
#####################################################
#input photo

image_index = 6
img = x_test[image_index]

img_input = img.reshape(1, 28, 28, 1)


plt.imshow(x_test[image_index].reshape(28, 28), cmap='gray')
#plt.imshow(img_array[0].reshape(28, 28), cmap='gray')
plt.title("Input Image")
plt.axis('off')
plt.show()


# prediction of the original model
original_pred = model.predict(img_input)
print("Original model prediction:", np.argmax(original_pred))