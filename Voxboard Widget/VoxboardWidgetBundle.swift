import WidgetKit
import SwiftUI

@main
struct VoxboardWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoxboardRecordWidget()
        if #available(iOSApplicationExtension 17.0, *) {
            VoxboardLiveActivity()
        }
        if #available(iOSApplicationExtension 18.0, *) {
            VoxboardRecordControl()
        }
    }
}
