import SwiftUI
import WidgetKit

@main
struct SecondChairWidgets: WidgetBundle {
    var body: some Widget {
        ContinueListeningWidget()
        ContinueOnIPhoneControl()
        ShowOnLockScreenControl()
    }
}
