import WidgetKit
import SwiftUI

struct RandomWordEntry: TimelineEntry {
    let date: Date
    let word: SharedWord?
}

struct RandomWordProvider: TimelineProvider {
    func placeholder(in context: Context) -> RandomWordEntry {
        RandomWordEntry(date: Date(), word: SharedWord(id: UUID(), surface: "日本", reading: "にほん", meaning: "Japan"))
    }
    
    func getSnapshot(in context: Context, completion: @escaping (RandomWordEntry) -> ()) {
        let words = SharedWordsIO.load()
        let entry = RandomWordEntry(date: Date(), word: words.randomElement())
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<RandomWordEntry>) -> ()) {
        let words = SharedWordsIO.load()
        let entry = RandomWordEntry(date: Date(), word: words.randomElement())
        // Refresh periodically (e.g., every 30 minutes) so different word appears throughout the day
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        let timeline = Timeline(entries: [entry], policy: .after(next))
        completion(timeline)
    }
}

struct RandomWordWidgetEntryView: View {
    var entry: RandomWordProvider.Entry
    
    var body: some View {
        if let w = entry.word {
            VStack(alignment: .leading, spacing: 4) {
                Text(w.surface)
                    .font(.headline)
                if !w.reading.isEmpty && w.reading != w.surface {
                    Text(w.reading)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !w.meaning.isEmpty {
                    Text(w.meaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding()
        } else {
            Text("No words yet")
                .padding()
        }
    }
}

struct RandomWordWidget: Widget {
    let kind: String = "RandomWordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RandomWordProvider()) { entry in
            RandomWordWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Random Word")
        .description("Shows a random saved word.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// NOTE: The @main WidgetBundle must live in the Widget Extension target, not the app target.
// Move this block to your widget extension and re-enable @main there.
#if false
@main
struct KyoukuWidgets: WidgetBundle {
    var body: some Widget {
        RandomWordWidget()
    }
}
#endif
