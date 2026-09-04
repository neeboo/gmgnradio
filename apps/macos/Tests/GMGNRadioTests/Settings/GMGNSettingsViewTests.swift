import Testing
@testable import GMGNRadio

@Test
func settingsPagesKeepTheAgreedTabOrder() {
    #expect(
        GMGNSettingsPage.allCases.map(\.rawValue) == [
            "角色",
            "音乐",
            "空间",
            "快捷键",
            "DJ",
        ]
    )
}

@Test
func settingsSpacePageKeepsOnlyLongTermServiceConfig() {
    #expect(GMGNSettingsSpacePage.sectionTitles == ["Marble 空间"])
    #expect(!GMGNSettingsSpacePage.sectionTitles.contains("3D 点阵"))
    #expect(!GMGNSettingsSpacePage.sectionTitles.contains("颗粒大小"))
}
