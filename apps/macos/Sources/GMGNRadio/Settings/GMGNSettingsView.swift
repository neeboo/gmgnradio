import SwiftUI

struct GMGNSettingsView: View {
    private enum Page: String, CaseIterable {
        case presence = "桌宠"
        case music = "音乐"
        case agent = "DJ"
    }

    @State private var page = Page.presence

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置", selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Group {
                switch page {
                case .presence:
                    PresenceSettingsView()
                case .music:
                    MusicAccountsView()
                case .agent:
                    AgentSettingsView()
                }
            }
        }
    }
}
