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
from tensorflow.keras.preprocessing import image
import matplotlib.pyplot as plt
from PIL import Image

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

#input photo

image_index = 6  # Number 7 for cr7 ;)
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


# 1️⃣ تحميل الصورة من ملف خارجي
img_path = "number3_black.png"   # ضع اسم ملفك هنا
img = Image.open(img_path).convert('L')  # تحويل لـ grayscale

# 2️⃣ تغيير الحجم إلى 28x28 مثل MNIST
img = img.resize((28, 28))

# 3️⃣ تحويل الصورة إلى numpy array وتطبيعها
img_array = np.array(img).astype('float32') / 255.0
img_array = img_array.reshape(1, 28, 28, 1)

# 4️⃣ عرض الصورة
plt.imshow(img_array.reshape(28, 28), cmap='gray')
plt.title("Input Image")
plt.axis('off')
plt.show()

# 5️⃣ التنبؤ باستخدام الموديل الأصلي
original_pred = model.predict(img_array)
print("Original model prediction:", np.argmax(original_pred))

################ Quantization with TensorFlow Lite to int8 ######################

# 1️⃣ Load dataset
(x_train, _), (_, _) = mnist.load_data()
x_train = x_train.astype(np.float32) / 255.0  # normalize

# 2️⃣ Load your Keras model
model = tf.keras.models.load_model('lenet5_model_good.h5')

# 3️⃣ Representative dataset generator
def representative_dataset():
    for i in range(100):  # خذ أول 100 صورة كمثال
        data = x_train[i].reshape(1, 28, 28, 1)
        yield [data.astype(np.float32)]

# 4️⃣ Convert to INT8 TFLite
converter = tf.lite.TFLiteConverter.from_keras_model(model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.representative_dataset = representative_dataset
converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
converter.inference_input_type = tf.int8
converter.inference_output_type = tf.int8

tflite_int8_model = converter.convert()

# 5️⃣ Save the quantized model
with open('lenet5_int8_good.tflite', 'wb') as f:
    f.write(tflite_int8_model)

print("✅ INT8 Quantized model saved as 'lenet5_int8_good.tflite'")

############ get destails about quantized model #####################
# 1️⃣ Load test dataset
(_, _), (x_test, y_test) = mnist.load_data()
x_test = x_test.astype(np.float32) / 255.0
x_test = x_test.reshape(-1, 28, 28, 1)

# 2️⃣ Load INT8 TFLite model
interpreter = tf.lite.Interpreter(model_path="lenet5_int8.tflite")
interpreter.allocate_tensors()

input_details = interpreter.get_input_details()
output_details = interpreter.get_output_details()

# 3️⃣ Prediction function
def predict(image):
    input_scale, input_zero_point = input_details[0]['quantization']
    image_int8 = (image / input_scale + input_zero_point).astype(np.int8)

    interpreter.set_tensor(input_details[0]['index'], image_int8)
    interpreter.invoke()

    output = interpreter.get_tensor(output_details[0]['index'])
    output_scale, output_zero_point = output_details[0]['quantization']
    output_float = output_scale * (output.astype(np.int32) - output_zero_point)

    return np.argmax(output_float)

# 4️⃣ Run predictions on all test data
predictions = []
for i in range(len(x_test)):
    pred = predict(x_test[i:i+1])
    predictions.append(pred)

predictions = np.array(predictions)

# 5️⃣ Accuracy
accuracy = np.mean(predictions == y_test)
print(f"✅ INT8 TFLite Model Accuracy: {accuracy*100:.2f}%")

# 6️⃣ Confusion Matrix
cm_q = confusion_matrix(y_test, predictions)
# print("\nConfusion Matrix:")
# print(cm)
plt.figure(figsize=(10, 8))
sns.heatmap(cm_q, annot=True, fmt='d', cmap='Blues')
plt.xlabel('Predicted')
plt.ylabel('Actual')
plt.title('Confusion Matrix for LeNet-5_int8 on MNIST')
plt.show()

# 7️⃣ Classification Report (Precision, Recall, F1-score)
report = classification_report(y_test, predictions)
print("\nClassification Report:")
print(report)

############## to get sacales of quantization ####################
    # بعد ما تعمل allocate_tensors
interpreter = tf.lite.Interpreter(model_path="lenet5_int8_good.tflite")
interpreter.allocate_tensors()

# الحصول على كل الـ tensors
all_details = interpreter.get_tensor_details()

print("\n🔎 Quantization Parameters لكل Layer:")
for d in all_details:
    name = d['name']
    shape = d['shape']
    dtype = d['dtype']
    scale, zero_point = d['quantization']
    print(f"Layer/Tensor: {name}")
    print(f"  Shape: {shape}")
    print(f"  Dtype: {dtype}")
    print(f"  Quantization scale: {scale}")
    print(f"  Quantization zero_point: {zero_point}")
    print("-"*60)