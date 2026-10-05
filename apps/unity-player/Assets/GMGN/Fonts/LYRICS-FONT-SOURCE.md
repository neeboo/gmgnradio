# Lyrics font derivatives

The five `GMGNLyricsSansSC-*.ttf` files are static weight instances of the
checked-in `NotoSansSC.ttf` variable font (Noto Sans SC). They retain upstream
copyright and SIL Open Font License metadata. `OFL.txt` applies to these files
and must accompany distribution. No Apple system font is embedded.

The derived family is **GMGN Lyrics Sans SC**, with Light 300, Medium 500,
Semibold 600, Bold 700 and Black 900. Naming is corrected explicitly because
the source's legacy family records contain “Thin”. Upstream license/designer
records are preserved. These remain sans-serif CJK faces; they do not claim
pixel-identical SF Rounded outlines.

Regenerate with an existing Python installation providing FontTools:

```sh
python3 apps/unity-player/Assets/GMGN/Fonts/generate-lyrics-fonts.py
```

`PlayerBuild.Prepare` creates separate lyric FontAssets, using dynamic SDF,
90-point sampling, 9-point padding, 1024-square multi-atlases. UI's existing
`PlayerRegularFont` remains unchanged. Glyph generation should be warmed during
song loading, not performed every frame; adding weights multiplies potential
atlas memory. The GPU renderer must associate each glyph with its actual font
atlas layer rather than assuming all weights share one texture.
