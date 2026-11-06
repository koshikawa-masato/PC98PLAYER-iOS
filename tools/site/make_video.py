"""Render an honest, silent slide guide from existing simulator screenshots.

Requires Pillow, ffmpeg with libx264, and Noto Sans CJK fonts on Linux.
Run from any directory: python3 tools/site/make_video.py
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs/videos"
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
SLIDES = [
    ("02-zip-in-files.png", "01", "「ファイル」で ZIP を展開", ["届いた ZIP をタップします。", "青いフォルダの「ファイル」アプリを使います。"]),
    ("03-extracted-folder.png", "02", "展開したフォルダを確認", ["ZIP と同じ場所にフォルダができます。", "練習用デモなら、このまま次へ。"]),
    ("05-folder-picker.png", "03", "アプリの「開く」で選択", ["作品のフォルダへ進み、右上の「開く」。", "中のファイルではなく、フォルダ全体を選びます。"]),
    ("06-transfer-success.png", "04", "デモが動いたら、入力してみる", ["「Transfer completed!」が起動の目印。", "キーを押して文字が出れば成功です。"]),
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if not Path(FONT).is_file() or not shutil.which("ffmpeg"):
        raise SystemExit("Noto Sans CJK and ffmpeg are required")
    font = lambda size: ImageFont.truetype(FONT, size)
    with tempfile.TemporaryDirectory(prefix="retrodos-video-") as temp:
        frames = Path(temp)
        for i, (filename, number, title, lines) in enumerate(SLIDES):
            canvas = Image.new("RGB", (1280, 720), "#f8f6ef")
            draw = ImageDraw.Draw(canvas)
            draw.rounded_rectangle((825, 18, 1248, 702), 22, fill="#e5eade")
            screenshot = Image.open(ROOT / "docs/tutorial/images" / filename).convert("RGB")
            screenshot.thumbnail((390, 650), Image.Resampling.LANCZOS)
            canvas.paste(screenshot, (1036 - screenshot.width // 2, 360 - screenshot.height // 2))
            draw.text((48, 48), "RetroDOS Player / はじめてのガイド", font=font(23), fill="#256247")
            draw.text((48, 135), number + " / 04", font=font(38), fill="#256247")
            draw.text((48, 225), title, font=font(32), fill="#252f2c")
            for j, line in enumerate(lines):
                draw.text((48, 325 + j * 50), line, font=font(26), fill="#37473d")
            draw.text((48, 594), "操作画像による手順説明・無音 / 各6秒", font=font(21), fill="#59645e")
            draw.text((48, 635), "iPhone シミュレーターの撮影例（2026年11月5日）", font=font(20), fill="#59645e")
            canvas.save(frames / f"{i:02}.png")
            if i == 0:
                canvas.save(OUT / "transfer-poster.jpg", quality=90)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-framerate", "1/6", "-i", str(frames / "%02d.png"),
            "-c:v", "libx264", "-preset", "medium", "-crf", "23",
            "-pix_fmt", "yuv420p", "-r", "24", "-movflags", "+faststart",
            str(OUT / "transfer-guide.mp4"),
        ], check=True)
    captions = "WEBVTT\n\n"
    for i, (_, _, title, lines) in enumerate(SLIDES):
        captions += f"00:00:{i*6:02}.000 --> 00:00:{(i+1)*6:02}.000\n{title}\n" + "\n".join(lines) + "\n\n"
    (OUT / "transfer-ja.vtt").write_text(captions.rstrip()+'\n', encoding="utf-8")


if __name__ == "__main__":
    main()
