"""Generate the blink overlays and soft shadow from the base art.
Run: python3 tools/make_effects.py   (Pillow)
"""
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

W = H = 900
SRC = 'assets/ruanmei.png'
orig = Image.open(SRC).convert('RGBA')
oa = np.asarray(orig)
rgb = oa[:, :, :3].astype(np.int16)

LEFT = [(330, 527), (333, 503), (352, 487), (378, 477), (410, 476), (434, 487),
        (446, 507), (443, 532), (432, 550), (410, 563), (380, 570), (352, 561), (337, 545)]
RIGHT = [(596, 522), (604, 500), (622, 484), (648, 476), (674, 480), (696, 495),
         (710, 515), (708, 540), (696, 556), (672, 567), (642, 569), (616, 560), (600, 544)]


def bez(p0, p1, p2, p3, n=50):
    out = []
    for i in range(n + 1):
        t = i / n
        out.append(((1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0],
                    (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1]))
    return out


def blink_overlay(close):
    ov = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    for poly, side in ((LEFT, 'L'), (RIGHT, 'R')):
        y0 = min(p[1] for p in poly)
        y1 = max(p[1] for p in poly)
        mask = Image.new('L', (W, H), 0)
        ImageDraw.Draw(mask).polygon(poly, fill=255)
        mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.3))
        m = np.array(mask)
        cut = int(y0 + (y1 - y0) * close)
        m[cut:, :] = 0
        fillmask = Image.fromarray(m)

        # skin gradient sampled from the face
        grad = Image.new('RGBA', (W, H))
        gd = ImageDraw.Draw(grad)
        top = (253, 243, 231)
        bot = (250, 231, 217)
        for y in range(int(y0) - 2, int(y1) + 2):
            t = (y - y0) / max(1, (y1 - y0))
            c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,)
            gd.line([(0, y), (W, y)], fill=c)
        ov.paste(grad, (0, 0), fillmask)
        fm = np.array(fillmask).astype(np.float32) / 255

        # soft shadow under the brow gives the closed lid volume
        sh = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        sd = ImageDraw.Draw(sh)
        sd.ellipse([min(p[0] for p in poly) - 8, y0 - 6,
                    max(p[0] for p in poly) + 8, y0 + 34],
                   fill=(200, 146, 138, 80))
        sh = sh.filter(ImageFilter.GaussianBlur(11))
        sa = np.array(sh).astype(np.float32)
        sa[:, :, 3] *= fm
        ov.alpha_composite(Image.fromarray(sa.clip(0, 255).astype(np.uint8)))

        # a slight lens tint so the eye still reads as being behind glass
        tint = np.zeros((H, W, 4), np.uint8)
        tint[:, :, 0] = 180; tint[:, :, 1] = 214; tint[:, :, 2] = 226
        tint[:, :, 3] = (fm * 20).astype(np.uint8)
        ov.alpha_composite(Image.fromarray(tint))

        d = ImageDraw.Draw(ov)
        if side == 'L':
            pts = bez((331, cut - 2), (365, cut + 8), (412, cut + 7), (444, cut - 6))
            cp = bez((342, cut - 14), (372, cut - 4), (414, cut - 5), (443, cut - 17))
            for k in range(3):
                d.line([(333, cut - 2), (319 - k * 2, cut - 11 + k * 5)], fill=(53, 38, 44, 255), width=2)
        else:
            pts = bez((600, cut), (630, cut + 10), (682, cut + 2), (708, cut - 16))
            cp = bez((610, cut - 14), (640, cut - 4), (682, cut - 12), (704, cut - 26))
            for k in range(3):
                d.line([(706, cut - 16), (720 + k * 2, cut - 25 + k * 5)], fill=(53, 38, 44, 255), width=2)
        d.line(pts, fill=(48, 34, 40, 255), width=7, joint='curve')
        d.line(cp, fill=(190, 142, 134, 100), width=3, joint='curve')

        # upper lid fold, between the brow and the lash line
        mid = y0 + (cut - y0) * 0.52
        if side == 'L':
            fold = bez((336, mid), (368, mid + 6), (412, mid + 5), (442, mid - 6))
        else:
            fold = bez((602, mid + 4), (632, mid + 8), (682, mid), (706, mid - 10))
        d.line(fold, fill=(186, 138, 130, 70), width=3, joint='curve')

        # faint lid highlight
        hl = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        hd = ImageDraw.Draw(hl)
        if side == 'L':
            hd.ellipse([352, mid + 4, 420, mid + 18], fill=(255, 252, 246, 55))
        else:
            hd.ellipse([618, mid + 2, 686, mid + 16], fill=(255, 252, 246, 50))
        hl = hl.filter(ImageFilter.GaussianBlur(6))
        ha = np.array(hl).astype(np.float32)
        ha[:, :, 3] *= fm
        ov.alpha_composite(Image.fromarray(ha.clip(0, 255).astype(np.uint8)))

        # lower lid hint
        if side == 'L':
            lp = bez((350, 566), (382, 576), (415, 570), (440, 548))
        else:
            lp = bez((605, 548), (625, 567), (682, 568), (703, 547))
        d.line(lp, fill=(212, 148, 140, 110), width=2, joint='curve')

        # faint lens reflection on the lid
        gl = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        gd = ImageDraw.Draw(gl)
        if side == 'L':
            gd.line([(345, 515), (385, 545)], fill=(255, 255, 255, 70), width=9)
            gd.line([(360, 505), (400, 535)], fill=(255, 255, 255, 45), width=4)
        else:
            gd.line([(620, 505), (660, 535)], fill=(255, 255, 255, 60), width=8)
            gd.line([(635, 495), (672, 523)], fill=(255, 255, 255, 40), width=3)
        gl = gl.filter(ImageFilter.GaussianBlur(5))
        ga = np.array(gl).astype(np.float32)
        ga[:, :, 3] *= np.array(fillmask).astype(np.float32) / 255
        ov.alpha_composite(Image.fromarray(ga.clip(0, 255).astype(np.uint8)))

    # restore hair only along the outer edges (glasses frame is left to the art below)
    r, g, b = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    mx = rgb.max(axis=2)
    hair = (mx < 120) & ((b - r) < 25)
    region = np.zeros((H, W), bool)
    for poly in (LEFT, RIGHT):
        mm = Image.new('L', (W, H), 0)
        ImageDraw.Draw(mm).polygon(poly, fill=255)
        mm = mm.filter(ImageFilter.MaxFilter(5))
        region |= np.asarray(mm) > 0
    le = np.zeros((H, W), bool); le[:, :364] = True
    re = np.zeros((H, W), bool); re[:, 684:] = True
    restore = hair & (le | re) & region
    fa = np.zeros((H, W, 4), np.uint8)
    fa[restore] = oa[restore]
    ov.alpha_composite(Image.fromarray(fa))
    return ov


def shadow():
    a = oa[:, :, 3].astype(np.float32) / 255
    # slight vertical squash + blur
    src = Image.fromarray((a * 255).astype(np.uint8))
    src = src.filter(ImageFilter.GaussianBlur(16))
    arr = np.zeros((H, W, 4), np.uint8)
    arr[:, :, 3] = (np.asarray(src) * 0.55).astype(np.uint8)
    return Image.fromarray(arr)


half = blink_overlay(0.60)
closed = blink_overlay(0.92)
half.save('assets/fx_blink_half.png')
closed.save('assets/fx_blink_closed.png')
shadow().save('assets/fx_shadow.png')
print('effects written')
