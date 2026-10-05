"""Reproducible OFL derivatives of the checked-in Noto Sans SC variable font."""
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parent
STYLES = {300: "Light", 500: "Medium", 600: "Semibold", 700: "Bold", 900: "Black"}

for weight, style in STYLES.items():
    source = TTFont(ROOT / "NotoSansSC.ttf")
    font = instantiateVariableFont(source, {"wght": weight}, inplace=True)
    family = "GMGN Lyrics Sans SC"
    # Derived family deliberately differs from upstream; retain copyright,
    # OFL license and designer metadata and correct inherited Thin labels.
    names = {1: family, 2: style, 3: f"GMGN-Lyrics-Sans-SC-{style}-1.0",
             4: f"{family} {style}", 6: f"GMGNLyricsSansSC-{style}",
             16: family, 17: style}
    for name_id, value in names.items():
        font["name"].removeNames(nameID=name_id)
        font["name"].setName(value, name_id, 3, 1, 0x409)
    font["OS/2"].usWeightClass = weight
    font["OS/2"].fsSelection &= ~(1 | 32 | 64)  # italic, bold, regular
    font["OS/2"].fsSelection |= 32 if weight >= 700 else 64
    font["head"].macStyle &= ~3
    if weight >= 700:
        font["head"].macStyle |= 1
    target = ROOT / f"GMGNLyricsSansSC-{style}.ttf"
    font.save(target)
    verified = TTFont(target, checkChecksums=2)
    assert "fvar" not in verified and verified["OS/2"].usWeightClass == weight
    assert verified["name"].getDebugName(1) == family
    assert verified["name"].getDebugName(2) == style
    assert len(verified.getBestCmap()) > 10000
    print(f"Verified {target.name}: weight={weight}, style={style}, glyphs={len(verified.getGlyphOrder())}")
