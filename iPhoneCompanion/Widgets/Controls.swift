import AppIntents
import SwiftUI
import WidgetKit

/// Continue on iPhone as a control: Lock Screen corners, Control Centre, the
/// Action button (22 November 2026). Runs in the background in the app.
struct ContinueOnIPhoneControl: ControlWidget {
    static let kind = "com.alistairmerritt.MusicStandBy.ContinueOnIPhone"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: WidgetContinueOnIPhoneIntent()) {
                Label("Continue on iPhone", systemImage: "iphone")
            }
        }
        .displayName("Continue on iPhone")
        .description("Plays your Mac’s music on this iPhone from the same point, and pauses your Mac.")
    }
}

/// Show on Lock Screen as a control. Opens Second Chair, the only way iOS
/// gives the player back once it has dropped it.
struct ShowOnLockScreenControl: ControlWidget {
    static let kind = "com.alistairmerritt.MusicStandBy.ShowOnLockScreen"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: WidgetShowOnLockScreenIntent()) {
                Label("Show on Lock Screen", systemImage: "lock.iphone")
            }
        }
        .displayName("Show on Lock Screen")
        .description("Opens Second Chair to put your Mac’s music back on the Lock Screen and in StandBy.")
    }
}
