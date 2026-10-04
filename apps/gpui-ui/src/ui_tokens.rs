//! Shared 2D typography and spacing. The system face uses GPUI's native
//! platform resolver (including Chinese fallback); no bundled font is needed.
//! Compact original inspector readouts remain explicit at their existing sizes.
pub const FONT_FAMILY: &str = ".SystemUIFont";
pub const BODY: f32 = 14.;
pub const CAPTION: f32 = 12.;
pub const SUBTITLE: f32 = 16.;
pub const TITLE: f32 = 20.;
pub const BODY_LINE_HEIGHT: f32 = 20.;
pub const CAPTION_LINE_HEIGHT: f32 = 16.;
pub const SPACING_4: f32 = 4.;
pub const SPACING_8: f32 = 8.;
pub const SPACING_12: f32 = 12.;
pub const SPACING_16: f32 = 16.;
pub const SPACING_24: f32 = 24.;

#[cfg(test)]
mod tests {
    #[test]
    fn embedded_player_sections_show_distinct_real_controls(){
        use crate::stage_panels::player_section_includes as includes;
        assert!(includes("歌词","lyrics"));assert!(!includes("歌词","clouds"));
        assert!(includes("视觉效果","clouds"));assert!(!includes("视觉效果","videoModes"));
        assert!(includes("视频","videoModes"));assert!(!includes("视频","lyrics"));
    }
    #[test]
    fn kit_small_control_uses_shared_semantic_text_size() {
        use gpui_kit::{Styled, div};
        use gpui_kit::component::Size;
        use gpui_kit::component::StyleSized;
        let mut label = div().button_text_size(Size::Small);
        let mut semantic = div().text_sm();
        assert_eq!(label.style().text_style().font_size, semantic.style().text_style().font_size);
    }
    #[test]
    fn hierarchy_and_spacing_are_stable() {
        assert_eq!([super::CAPTION, super::BODY, super::SUBTITLE, super::TITLE], [12., 14., 16., 20.]);
        assert_eq!([super::SPACING_4, super::SPACING_8, super::SPACING_12, super::SPACING_16, super::SPACING_24], [4., 8., 12., 16., 24.]);
        assert_eq!(super::FONT_FAMILY, ".SystemUIFont");
    }

    #[test]
    fn stage_style_choices_have_named_button_roles() {
        let (role, label) = crate::stage_panels::style_choice_accessibility("字幕特效", "经典", true);
        assert_eq!(role, gpui_kit::Role::Button);
        assert_eq!(label, "字幕特效：经典，已选择");
        assert_eq!(crate::stage_panels::style_choice_accessibility("字幕特效", "经典", false).1, "字幕特效：经典");
    }
}
