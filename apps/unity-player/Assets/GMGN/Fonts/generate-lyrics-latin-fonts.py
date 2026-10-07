"""Same-weight Noto Sans fallbacks; original SC outlines remain untouched."""
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parent
for weight, style in {300: "Light", 500: "Medium", 600: "Semibold", 700: "Bold", 900: "Black"}.items():
    font = instantiateVariableFont(TTFont(ROOT / "NotoSansLatin.ttf"), {"wght": weight, "wdth": 100}, inplace=True)
    family = "GMGN Lyrics Latin"
    for name_id, value in {1: family, 2: style, 3: f"GMGN-Lyrics-Latin-{style}-1.0", 4: f"{family} {style}", 6: f"GMGNLyricsLatin-{style}", 16: family, 17: style}.items():
        font["name"].removeNames(nameID=name_id)
        font["name"].setName(value, name_id, 3, 1, 0x409)
    font["OS/2"].usWeightClass = weight
    font.save(ROOT / f"GMGNLyricsLatin-{style}.ttf")
    assert 0x142 in font.getBestCmap() and 0x141 in font.getBestCmap()
    print(f"Verified Latin fallback {style}: weight={weight}, łŁ present")
