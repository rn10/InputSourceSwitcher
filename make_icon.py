# アプリアイコン(icon.png, 1024x1024)を生成するスクリプト。
# 黒に近いグレーの角丸背景に、左上「あ」/右下「a」を太字(Bold)で対角配置。
# 太字にしているのは、小サイズ(16/32px)でも潰れず判読できるようにするため。
# 実行後、AppIcon.iconset を作り、build.sh が iconutil で .icns 化する。
from PIL import Image, ImageDraw, ImageFont

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pad = 100
box = (pad, pad, S - pad, S - pad)
radius = 185

top = (54, 54, 60); bottom = (30, 30, 34)   # #36363C -> #1E1E22
grad = Image.new("RGB", (1, S))
for y in range(S):
    t = y / (S - 1)
    grad.putpixel((0, y), tuple(int(top[i]*(1-t)+bottom[i]*t) for i in range(3)))
grad = grad.resize((S, S))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
img.paste(grad, (0, 0), mask)

# Bold（環境に応じてパスは変更可）。index=0 が JP。
font_path = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
draw = ImageDraw.Draw(img)
ink = (245, 245, 248, 255)

def draw_centered(ch, cx, cy, size):
    font = ImageFont.truetype(font_path, size, index=0)
    l, t, r, b = draw.textbbox((0, 0), ch, font=font)
    draw.text((cx-(r-l)/2 - l, cy-(b-t)/2 - t), ch, font=font, fill=ink)

draw_centered("あ", int(S*0.35), int(S*0.35), 370)
draw_centered("a",  int(S*0.65), int(S*0.65), 370)

img.save("icon.png")
print("saved icon.png")
