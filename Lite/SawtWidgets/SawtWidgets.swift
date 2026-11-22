import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SawtWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CallLiveActivity()
    }
}

struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { ctx in
            // شاشة القفل
            HStack(spacing: 12) {
                Image(systemName: ctx.state.icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("مكالمة صوت لايت").font(.headline)
                    Text(ctx.state.label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().font(.subheadline)
                    .frame(width: 56)
                Button(intent: ToggleMuteIntent()) {
                    Image(systemName: ctx.state.muted ? "mic.slash.fill" : "mic.fill")
                }
                .tint(.gray)
                Button(intent: EndCallIntent()) {
                    Image(systemName: "phone.down.fill")
                }
                .tint(.red)
            }
            .padding()
            .environment(\.layoutDirection, .rightToLeft)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.state.label, systemImage: ctx.state.icon)
                        .font(.subheadline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit().font(.subheadline)
                        .frame(width: 56)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 16) {
                        Button(intent: ToggleMuteIntent()) {
                            Label(ctx.state.muted ? L("شغّل الميكروفون") : L("اكتم"), systemImage: ctx.state.muted ? "mic.fill" : "mic.slash.fill")
                        }
                        .tint(.gray)
                        Button(intent: EndCallIntent()) {
                            Label("إنهاء", systemImage: "phone.down.fill")
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: ctx.state.icon).foregroundStyle(.blue)
            } compactTrailing: {
                Text(timerInterval: ctx.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().frame(width: 40)
            } minimal: {
                Image(systemName: ctx.state.icon).foregroundStyle(.blue)
            }
        }
    }
}
