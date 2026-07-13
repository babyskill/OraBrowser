import os
from PIL import Image

source_path = "assets/icon.png"
if not os.path.exists(source_path):
    print(f"Error: {source_path} not found.")
    exit(1)

# Thư mục appiconset
appiconsets = [
    "ora/Assets/Catalogs/Assets.xcassets/OraIcon.appiconset",
    "ora/Assets/Catalogs/Assets.xcassets/OraIconDev.appiconset"
]

sizes = {
    "ora-white-macos-icon.png": (16, 16),
    "Icon-32 1.png": (32, 32),
    "Icon-32.png": (32, 32),
    "Icon-64.png": (64, 64),
    "Icon-128.png": (128, 128),
    "Icon-256.png": (256, 256),
    "Icon-256 1.png": (256, 256),
    "Icon-512.png": (512, 512),
    "Icon-512 1.png": (512, 512),
    "Icon-1024.png": (1024, 1024),
    "Icon.png": (1024, 1024)
}

img = Image.open(source_path)

for appiconset in appiconsets:
    if not os.path.exists(appiconset):
        os.makedirs(appiconset, exist_ok=True)
    for filename, size in sizes.items():
        dest_path = os.path.join(appiconset, filename)
        resized_img = img.resize(size, Image.Resampling.LANCZOS)
        resized_img.save(dest_path, "PNG")
        print(f"Updated {dest_path} to {size}")

print("All icons updated successfully.")
