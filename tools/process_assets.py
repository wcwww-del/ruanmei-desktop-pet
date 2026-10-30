from PIL import Image, ImageDraw, ImageFilter, ImageChops
import numpy as np, os

SRC = '阮·梅.png'
OUT_PET = 'assets/ruanmei.png'
OUT_ICON = 'assets/AppIcon.iconset'

im = Image.open(SRC).convert('RGB')
w, h = im.size

# --- background removal: flood fill from all four corners through near-white ---
# Use a working copy with a sentinel fill colour.
filled = im.copy()
sentinel = (255, 0, 255)
for seed in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w // 2, 0), (w // 2, h - 1)]:
    if filled.getpixel(seed) != sentinel:
        ImageDraw.floodfill(filled, seed, sentinel, thresh=38)

arr = np.asarray(filled).astype(np.int16)
bg = (arr[:, :, 0] > 250) & (arr[:, :, 1] < 5) & (arr[:, :, 2] > 250)

alpha = np.where(bg, 0, 255).astype(np.uint8)
a_img = Image.fromarray(alpha, 'L')

# Shrink alpha by ~1px to drop the white anti-aliased fringe, then feather.
a_img = a_img.filter(ImageFilter.MinFilter(3))
a_img = a_img.filter(ImageFilter.GaussianBlur(0.9))
# Re-sharpen the interior so only the rim is soft.
a_np = np.asarray(a_img).astype(np.float32)
a_np = np.clip((a_np - 18) * 1.16, 0, 255)
alpha = a_np.astype(np.uint8)
# Keep only the character body: drop detached specks (e.g. the stray line
# underneath the badge in the source artwork).
from collections import deque
small = np.array(Image.fromarray(alpha).resize((512, 512), Image.NEAREST)) > 20
hh, ww = small.shape
labels = np.zeros((hh, ww), np.int32)
sizes = []
cur = 0
for sy in range(hh):
    for sx in range(ww):
        if small[sy, sx] and labels[sy, sx] == 0:
            cur += 1
            q = deque([(sy, sx)])
            labels[sy, sx] = cur
            n = 0
            while q:
                y, x = q.popleft()
                n += 1
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < hh and 0 <= nx < ww and small[ny, nx] and labels[ny, nx] == 0:
                            labels[ny, nx] = cur
                            q.append((ny, nx))
            sizes.append((n, cur))
sizes.sort(reverse=True)
keep_label = sizes[0][1]
keep = Image.fromarray((labels == keep_label).astype(np.uint8) * 255).resize(im.size, Image.NEAREST)
alpha = (alpha.astype(np.float32) * (np.asarray(keep) > 0)).clip(0, 255).astype(np.uint8)

rgba = np.dstack([np.asarray(im).astype(np.uint8), alpha])
out = Image.fromarray(rgba, 'RGBA')

# --- trim to content with a little breathing room ---
bbox = out.getbbox()
pad = 12
box = (max(bbox[0] - pad, 0), max(bbox[1] - pad, 0),
       min(bbox[2] + pad, out.width), min(bbox[3] + pad, out.height))
out = out.crop(box)
# square canvas so the pet never jumps around when scaled
side = max(out.size)
canvas = Image.new('RGBA', (side, side), (0, 0, 0, 0))
canvas.paste(out, ((side - out.width) // 2, (side - out.height) // 2), out)
canvas = canvas.resize((900, 900), Image.LANCZOS)
canvas.save(OUT_PET, optimize=True)
print('pet', OUT_PET, canvas.size, os.path.getsize(OUT_PET))

# --- previews on light/dark to eyeball the matte ---
for name, bgc in [('light', (246, 244, 238, 255)), ('dark', (28, 32, 40, 255)), ('magenta', (220, 30, 160, 255))]:
    p = Image.new('RGBA', (760, 760), bgc)
    p.alpha_composite(canvas, (20, 20))
    p.convert('RGB').save(f'/tmp/preview_{name}.jpg', quality=92)

# --- app icon ---
os.makedirs(OUT_ICON, exist_ok=True)
S = 1024
icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
bg_layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
grad = Image.new('RGB', (S, S))
top = (24, 48, 54)
bot = (10, 22, 26)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3))
    ImageDraw.Draw(grad).line([(0, y), (S, y)], fill=c)
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=225, fill=255)
bg_layer.paste(grad, (0, 0), mask)
# soft glow behind the character
glow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([180, 200, 844, 864], fill=(120, 200, 190, 70))
glow = glow.filter(ImageFilter.GaussianBlur(90))
icon.alpha_composite(glow)
icon.alpha_composite(bg_layer)
char = canvas.resize((780, 780), Image.LANCZOS)
icon.alpha_composite(char, (122, 150))
# thin inner ring
ring = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ring).rounded_rectangle([26, 26, S - 27, S - 27], radius=205, outline=(255, 255, 255, 40), width=3)
icon.alpha_composite(ring)
for s in [16, 32, 64, 128, 256, 512]:
    icon.resize((s, s), Image.LANCZOS).save(f'{OUT_ICON}/icon_{s}x{s}.png')
    icon.resize((s * 2, s * 2), Image.LANCZOS).save(f'{OUT_ICON}/icon_{s}x{s}@2x.png')
print('icon set written')
